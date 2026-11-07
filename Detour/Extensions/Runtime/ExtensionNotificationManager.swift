import Foundation
import UserNotifications
import WebKit
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
    /// The identifiers of every notification of Detour's on screen or in
    /// Notification Center, whichever launch or build showed it. Listing never
    /// prompts the user, whatever the authorization status (TASK-248).
    func deliveredIdentifiers() async -> [String]
    /// The identifiers of every request of Detour's not yet delivered.
    func pendingIdentifiers() async -> [String]
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
    /// `registerDismissCategory`'s registration. The authorization check
    /// waits for it, and every `add` waits for that check (the manager's
    /// `authorize()`, which keeps the adds in call order), so no notification
    /// is shown before its category is registered (one that was might not
    /// report a dismissal).
    private var dismissCategoryRegistration: Task<Void, Never>?

    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    func removeNotifications(withIdentifiers identifiers: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func authorizationStatus() async -> ExtensionNotificationAuthorization {
        await dismissCategoryRegistration?.value
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

    func deliveredIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier)
    }

    func pendingIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
    }

    /// Registers `ExtensionNotificationManager.dismissCategory` (TASK-247),
    /// keeping any category something else of Detour's registered:
    /// `setNotificationCategories` replaces the whole set. Asynchronous; see
    /// `dismissCategoryRegistration` for what waits for it.
    func registerDismissCategory() {
        let center = UNUserNotificationCenter.current()
        let category = ExtensionNotificationManager.dismissCategory
        dismissCategoryRegistration = Task {
            let existing = await center.notificationCategories()
            let others = existing.filter { $0.identifier != category.identifier }
            center.setNotificationCategories(others.union([category]))
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
/// reload), `removeAll(profileID:)` when the profile is deleted,
/// `removeSession(profileID:)` when a Private session starts or ends, so
/// nothing carries over into the next one, and `revoke(for:refusal:)` when
/// the extension loses the `notifications` permission in the profile.
/// A notification also goes when its banner does (TASK-272): the user
/// dismisses it or clicks it (macOS takes a clicked banner away), or it
/// leaves Notification Center without a report, which
/// `synchronizeWithCenter` finds at the next `create` or periodic check.
/// Each of these fires `onClosed` with `byUser` true.
///
/// A notification is recorded when `create` is called, before the center's
/// `add` returns, so the calls an extension makes without awaiting apply in
/// the order it made them (TASK-234): a `clear` issued while the `add` is in
/// flight drops the entry at once, and when that `add` returns the manager
/// takes the notification away again, in case the center showed it after the
/// clear. An `update` issued meanwhile finds the entry and re-creates it under
/// the same identifier. Each `create` carries a generation, so an `add` that a
/// later `create` for the same id has superseded leaves the newer entry alone:
/// the newer `add` replaces what it showed. An `update` whose `add` fails puts
/// back the entry it replaced (TASK-271), as the notification that entry
/// stands for is still shown; a failed `create` drops its entry.
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
    /// delegate. Created at launch to remove the notifications earlier
    /// launches left (`removeLeftoverNotifications`), or at the first
    /// notification call when launch skips that.
    static var shared: ExtensionNotificationManager {
        if let sharedInstance { return sharedInstance }
        let system = SystemExtensionNotificationCenter()
        system.registerDismissCategory()
        let manager = ExtensionNotificationManager(center: system)
        UNUserNotificationCenter.current().delegate = manager
        sharedInstance = manager
        return manager
    }

    /// `shared` if anything has created it this launch, else nil: with no
    /// manager there is no notification to take away, so a profile or session
    /// ending does not set up the system center. Launch creates it to remove
    /// leftovers, so it is nil only where launch skipped that (the XCTest
    /// host, or another Detour process running).
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
        /// Which `create` or `update` recorded the entry (or, once a failed
        /// update has put it back, the fallback's); see `addFinished`.
        let generation: Int
        /// The options the notification shows (`shownOptionKeys` only): the
        /// create's, with every later update's merged in (TASK-240). What the
        /// next `update` merges into.
        let options: [String: Any]
        /// For an update: the entries it replaced that still stand for
        /// something shown, or being shown, under the identifier, newest
        /// first (TASK-271). If this update's `add` fails, the first is put
        /// back. Only the generations whose `add` has not failed or been
        /// skipped are kept, and none older than one whose `add` succeeded;
        /// see `addFinished`. Empty for a create, which replaces outright, and
        /// once this entry's own `add` has succeeded.
        var fallbacks: [Fallback] = []
        /// When this generation's `add` succeeded, so the center has shown
        /// it; nil while it is in flight (or waiting for authorization).
        /// `synchronizeWithCenter` checks only shown entries (TASK-272).
        var shownAt: ContinuousClock.Instant?
    }

    /// An entry an update replaced, as `Entry.fallbacks` keeps it.
    private struct Fallback {
        let generation: Int
        let options: [String: Any]
        /// The replaced entry's `shownAt`, set here too if its `add`
        /// succeeds after the update replaced it.
        var shownAt: ContinuousClock.Instant?
    }

    /// UNNotification identifier → the notification an owner has and has not
    /// cleared, including one whose `add` is still in flight.
    private var entries: [String: Entry] = [:]
    /// The inverse of `entries`: each such notification's identifier.
    private var identifiers: [Key: String] = [:]
    private var lastGeneration = 0
    private let center: any ExtensionNotificationCenter
    /// The clock `shownAt` and `synchronizeWithCenter`'s grace read. A seam:
    /// a test moves time on instead of waiting.
    var now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }

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
    /// build's from an earlier launch: the map lives in memory only. Launch
    /// removes all of them (`removeLeftoverNotifications`, TASK-248).
    static let identifierPrefix = "detour-ext-notification.v3|"

    /// The category every extension notification carries (TASK-247). Its
    /// `.customDismissAction` makes the center tell the delegate when the
    /// user dismisses a banner (`UNNotificationDismissActionIdentifier`);
    /// without it a dismissal is never reported, so the entry would outlive
    /// the banner and `onClosed` could not fire. No actions: Chrome's
    /// `buttons` are not shown. The identifier names no profile or extension.
    static let dismissCategory = UNNotificationCategory(
        identifier: "detour-ext-notification", actions: [], intentIdentifiers: [],
        options: [.customDismissAction])

    /// The prefix of the identifiers TASK-238's first build handed out:
    /// `detour-ext-notification.v2|<profile UUID>|<extension id>|<id>`.
    private static let v2IdentifierPrefix = "detour-ext-notification.v2|"

    /// The identifiers builds before TASK-238 handed out:
    /// `<extension id>:<notification id>`, where the extension id is the one
    /// Detour keys its contexts by, a Chrome-style id (32 letters a–p, from
    /// the CRX key) or, for an unpacked extension with no key, a UUID string.
    /// Anchored on that id shape so an identifier of anything else that posts
    /// as Detour (Sparkle's update reminder) is never taken for one.
    private static let legacyIdentifier =
        /^(?:[a-p]{32}|[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}):/

    /// Whether `identifier` has the shape of an extension notification some
    /// Detour build showed: v3 (this build's), v2 or legacy.
    static func isExtensionNotificationIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix)
            || identifier.hasPrefix(v2IdentifierPrefix)
            || identifier.prefixMatch(of: legacyIdentifier) != nil
    }

    /// Takes away every extension notification, delivered or pending, that an
    /// earlier launch showed (TASK-248). Nothing maps one back to its owner
    /// any more, so a click on it would be ignored and the extension's `clear`
    /// could not reach it. Called once at launch.
    ///
    /// An identifier this launch handed out and still has an entry for is
    /// kept: the listing is awaited, so an extension may create a
    /// notification before it answers, and the filter runs after. One this
    /// launch handed out and has since dropped is removed again, which is
    /// harmless. Not gated on authorization: listing never prompts, and a user
    /// who turned notifications off may still have banners from before.
    func removeLeftoverNotifications() async {
        let leftovers = await listedIdentifiers().filter {
            Self.isExtensionNotificationIdentifier($0) && entries[$0] == nil
        }
        guard !leftovers.isEmpty else { return }
        log.info("Removing \(leftovers.count) extension notification(s) left by an earlier launch")
        center.removeNotifications(withIdentifiers: leftovers.sorted())
    }

    /// Every identifier the center lists, pending or delivered. Pending is
    /// listed first: a request only ever moves from pending to delivered, so
    /// one that moves between the two listings is in the second, never in
    /// neither.
    private func listedIdentifiers() async -> Set<String> {
        let pending = await center.pendingIdentifiers()
        return Set(pending).union(await center.deliveredIdentifiers())
    }

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
    /// Title, body and subtitle only, and the one category every extension
    /// notification shares: nothing that names the profile (no
    /// threadIdentifier, no userInfo), for the same reason as the identifier.
    static func content(for options: [String: Any]) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = options["title"] as? String ?? ""
        content.body = options["message"] as? String ?? ""
        content.subtitle = options["contextMessage"] as? String ?? ""
        content.categoryIdentifier = dismissCategory.identifier
        return content
    }

    /// The option fields `content(for:)` reads: all an entry keeps for the
    /// next `update` to merge into. Not the rest (an `iconUrl` or `imageUrl`
    /// is often a large data: URL), since an entry lives as long as its
    /// banner, which may be all session.
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
    ///
    /// Each create also checks the shown entries against the center
    /// (`synchronizeWithCenter`, coalesced and throttled), so the entries of an extension
    /// that never clears cannot outgrow what is on screen (TASK-272).
    ///
    /// A nil or empty `notificationID` gets a generated id, as Chrome's does
    /// for one "not set or empty" (TASK-269): an empty id is never kept.
    func create(owner: Owner, notificationID: String?, options: [String: Any], completion: @escaping (String) -> Void) {
        let given = notificationID?.isEmpty == false ? notificationID : nil
        show(owner: owner, notificationID: given, options: options, isUpdate: false) { id, _ in completion(id) }
        synchronizeAfterCreate()
    }

    /// `create`, also telling `completion` whether the notification was
    /// shown: false when notifications are not allowed or the `add` failed.
    /// `isUpdate`: the entry being replaced is kept as a fallback, put back
    /// if this `add` fails (TASK-271).
    private func show(owner: Owner, notificationID: String?, options: [String: Any], isUpdate: Bool,
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

        var fallbacks: [Fallback] = []
        if isUpdate, let existingIdentifier, let replaced = entries[existingIdentifier] {
            fallbacks = [Fallback(generation: replaced.generation, options: replaced.options,
                                  shownAt: replaced.shownAt)] + replaced.fallbacks
        }

        lastGeneration += 1
        let generation = lastGeneration
        entries[identifier] = Entry(owner: owner, notificationID: id, generation: generation,
                                    options: options.filter { Self.shownOptionKeys.contains($0.key) },
                                    fallbacks: fallbacks)
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
            // skipping this one keeps a stale add from landing after it. As
            // nothing of this generation's will show, a failure of the
            // superseding update must not put it back.
            guard self.isCurrent(identifier: identifier, generation: generation) else {
                self.dropFallback(identifier: identifier, generation: generation)
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

    /// Forgets `generation` as a fallback of `identifier`'s current entry:
    /// its `add` failed or was skipped, so nothing of it is shown.
    private func dropFallback(identifier: String, generation: Int) {
        guard var entry = entries[identifier], !entry.fallbacks.isEmpty else { return }
        entry.fallbacks.removeAll { $0.generation == generation }
        entries[identifier] = entry
    }

    /// Settles the entry an `add` was for, now that the center has answered.
    private func addFinished(identifier: String, generation: Int, failure: (any Error)?) {
        if let failure {
            log.error("Failed to show notification \(identifier, privacy: .private): \(failure.localizedDescription)")
        }
        guard var entry = entries[identifier] else {
            // Cleared (or removed with its owner) while the `add` was in
            // flight. That removal may have reached the center before the
            // notification did. A later `create` for the same id has a new
            // identifier, so this takes away only what this `add` showed.
            center.removeNotifications(withIdentifiers: [identifier])
            return
        }
        guard entry.generation == generation else {
            // A later `create` or `update` for the same id owns the identifier
            // now. Its `add` replaces whatever this one showed, and settles
            // the entry itself; this one only keeps its fallbacks true: a
            // failed generation shows nothing to fall back to, and a shown one
            // replaced everything older.
            if failure == nil {
                guard !entry.fallbacks.isEmpty else { return }
                entry.fallbacks.removeAll { $0.generation < generation }
                if let index = entry.fallbacks.firstIndex(where: { $0.generation == generation }) {
                    entry.fallbacks[index].shownAt = now()
                    // Shown, so checked once a failed update puts it back.
                    scheduleSynchronization()
                }
                entries[identifier] = entry
            } else {
                dropFallback(identifier: identifier, generation: generation)
            }
            return
        }
        guard failure != nil else {
            entry.fallbacks = []
            entry.shownAt = now()
            entries[identifier] = entry
            scheduleSynchronization()
            return
        }
        if let restored = entry.fallbacks.first {
            // A failed update (TASK-271): the center showed nothing new, and
            // the notification the replaced entry stands for is still shown,
            // or its own `add` settles it. Chrome leaves it in place too.
            entries[identifier] = Entry(owner: entry.owner, notificationID: entry.notificationID,
                                        generation: restored.generation, options: restored.options,
                                        fallbacks: Array(entry.fallbacks.dropFirst()),
                                        shownAt: restored.shownAt)
            return
        }
        removeEntry(identifier: identifier)
        // Nothing new is shown, but a notification an earlier `create`
        // showed under this id still may be; the extension no longer has it.
        center.removeNotifications(withIdentifiers: [identifier])
    }

    /// Update an existing notification of `owner`'s, including one whose
    /// `create` has not finished yet. The given options are merged into the
    /// notification's, as Chrome does: an update that sets only `message`
    /// keeps the title. Answers false when the owner has no such notification,
    /// when notifications are not allowed (which drops it), or when the
    /// center refuses the updated one, which leaves the notification as it
    /// was, listed and shown (TASK-271).
    func update(owner: Owner, notificationID: String, options: [String: Any], completion: @escaping (Bool) -> Void) {
        guard let identifier = identifier(for: owner, notificationID: notificationID),
              let entry = entries[identifier] else {
            completion(false)
            return
        }
        // Re-create with the merged content. A failed `add` puts the entry
        // this replaces back (see `addFinished`): the update did not apply.
        let merged = Self.merged(options, into: entry.options)
        show(owner: owner, notificationID: notificationID, options: merged, isUpdate: true) { _, succeeded in
            completion(succeeded)
        }
    }

    /// Clear a notification of `owner`'s, including one whose `create` has not
    /// finished yet. Answers whether the owner had such a notification, as
    /// Chrome's `clear` does (TASK-240). Another owner's notification with the
    /// same id is a different notification, so it is untouched and the answer
    /// is false. A clear that finds one fires `onClosed` with `byUser` false
    /// (TASK-247), as Chrome's does: its `clear` closes the notification with
    /// `by_user` false, and that close reaches the extension as `onClosed`
    /// (see the polyfill-layer wiki).
    func clear(owner: Owner, notificationID: String, completion: @escaping (Bool) -> Void) {
        guard let identifier = identifier(for: owner, notificationID: notificationID) else {
            completion(false)
            return
        }
        removeEntry(identifier: identifier)
        center.removeNotifications(withIdentifiers: [identifier])
        deliver([(.closed, byUser: false)], notificationID: notificationID, to: owner)
        completion(true)
    }

    /// Takes away every notification of `owner`'s, delivered or still pending,
    /// including one whose `create` has not finished yet (its `add` takes it
    /// away again when it returns; see `addFinished`). For an extension
    /// unloaded from a profile.
    func removeAll(for owner: Owner) {
        removeAll { $0.owner == owner }
        dropEventChannels { $0 == owner }
    }

    /// `removeAll(for:)` for every extension's notifications in the profile.
    /// For a deleted profile: its contexts are gone, so their parks are
    /// answered and their channels forgotten.
    func removeAll(profileID: UUID) {
        removeAll { $0.owner.profileID == profileID }
        dropEventChannels { $0.profileID == profileID }
    }

    /// Takes away every extension's notifications in the profile, delivered
    /// or still pending, and the events queued for them, as `removeAll(profileID:)`
    /// does, but leaves its contexts listening. For a Private session starting
    /// or ending (TASK-264): the Private profile's contexts stay loaded between
    /// sessions, so its worker's park belongs to a context that is still
    /// running. Answering it as `removeAll` does ("the extension was
    /// unloaded") would be final for that context (the polyfill never parks
    /// again after it), and every later click and close would wait in the
    /// backlog unheard until WebKit restarted the worker.
    func removeSession(profileID: UUID) {
        removeAll { $0.owner.profileID == profileID }
        for owner in eventChannels.keys where owner.profileID == profileID {
            eventChannels[owner]?.backlog.removeAll()
        }
    }

    /// Takes away every notification of `owner`'s, delivered or still
    /// pending, and the events queued for them, when the `notifications`
    /// permission stops being active for it (TASK-270): the Settings switch
    /// turned off, or the extension's own `permissions.remove` of the
    /// optional permission. A parked wait is answered with `refusal`, the
    /// handler's permission refusal, so the polyfill takes it as "not
    /// granted (yet)" and parks again at its next notifications call once a
    /// grant serves one (TASK-250); "unloaded" would end its waiting for
    /// good. The channel's incarnations stay, so the re-park is accepted and
    /// an older worker is still refused. With nothing left to click or
    /// close, no event reaches the extension until it creates a notification
    /// again, which only a new grant lets it do.
    func revoke(for owner: Owner, refusal: String) {
        removeAll { $0.owner == owner }
        guard var channel = eventChannels[owner] else { return }
        let parked = channel.parked
        channel.parked = nil
        channel.backlog.removeAll()
        eventChannels[owner] = channel
        parked?.reply(nil, refusal)
    }

    private func removeAll(where matches: (Entry) -> Bool) {
        let removed = entries.filter { matches($0.value) }.map(\.key)
        guard !removed.isEmpty else { return }
        for identifier in removed { removeEntry(identifier: identifier) }
        log.info("Removed \(removed.count) extension notification(s) whose owner went away")
        center.removeNotifications(withIdentifiers: removed)
    }

    // MARK: - Notifications macOS took away unreported (TASK-272)

    /// How long after its `add` succeeded a notification must be missing
    /// from the center's listing before it counts as gone: the center may
    /// list a notification a moment after the `add` answers (the foreground
    /// presentation asks the delegate first).
    static let synchronizationGrace: Duration = .seconds(5)
    /// How often the shown entries are checked against the center while
    /// there are any: Chrome's `kSynchronizationInterval`.
    static let synchronizationInterval: TimeInterval = 10 * 60

    private var synchronizationTimer: Timer?
    /// The synchronization `synchronizeInBackground` started, until it ends.
    private var backgroundSynchronization: Task<Void, Never>?
    /// When `synchronizeWithCenter` last listed the center: a create
    /// synchronizes at most once per `synchronizationGrace`, so an extension
    /// re-creating a notification many times a second does not list
    /// usernoted at every call.
    private var lastListing: ContinuousClock.Instant?

    /// Drops every entry whose notification the center no longer lists,
    /// delivered or pending, and fires `onClosed` with `byUser` true for it,
    /// as Chrome's `SynchronizeNotifications` does for a notification that
    /// left Notification Center without a reported dismissal ("Clear All",
    /// the system pruning old ones). Only entries shown at least
    /// `synchronizationGrace` ago are checked; an entry whose `add` is in
    /// flight (a create, or an update over a shown one) is left alone, as
    /// Chrome leaves one with pending content: that `add` shows it again.
    /// An entry cleared, removed with its owner, clicked or replaced during
    /// the listing is skipped, so it gets no second event.
    func synchronizeWithCenter() async {
        let threshold = now() - Self.synchronizationGrace
        let candidates = entries.compactMap { identifier, entry -> (identifier: String, generation: Int)? in
            guard let shownAt = entry.shownAt, shownAt <= threshold else { return nil }
            return (identifier, entry.generation)
        }
        guard !candidates.isEmpty else { return }
        lastListing = now()
        let listed = await listedIdentifiers()
        var gone: [(identifier: String, entry: Entry)] = []
        for candidate in candidates where !listed.contains(candidate.identifier) {
            guard let entry = entries[candidate.identifier], entry.generation == candidate.generation else { continue }
            removeEntry(identifier: candidate.identifier)
            gone.append((candidate.identifier, entry))
        }
        guard !gone.isEmpty else { return }
        log.info("\(gone.count) extension notification(s) left Notification Center unreported; closing them")
        // In case the listing missed one still shown: with its entry gone,
        // nothing else could take it away, and a click on it is ignored.
        center.removeNotifications(withIdentifiers: gone.map(\.identifier))
        for (_, entry) in gone {
            deliver([(.closed, byUser: true)], notificationID: entry.notificationID, to: entry.owner)
        }
    }

    /// A create's synchronization: `synchronizeInBackground`, unless the
    /// center was listed less than `synchronizationGrace` ago.
    private func synchronizeAfterCreate() {
        if let lastListing, now() - lastListing < Self.synchronizationGrace { return }
        synchronizeInBackground()
    }

    /// `synchronizeWithCenter` from a task, unless one is already running.
    private func synchronizeInBackground() {
        guard backgroundSynchronization == nil else { return }
        backgroundSynchronization = Task { [weak self] in
            await self?.synchronizeWithCenter()
            self?.backgroundSynchronization = nil
        }
    }

    /// Starts the repeating check once a notification is shown; it stops at
    /// the first tick that finds no entries.
    private func scheduleSynchronization() {
        guard synchronizationTimer == nil else { return }
        synchronizationTimer = Timer.scheduledMainTimer(withTimeInterval: Self.synchronizationInterval,
                                                        repeats: true) { [weak self] timer in
            guard let self, !self.entries.isEmpty else {
                timer.invalidate()
                self?.synchronizationTimer = nil
                return
            }
            self.synchronizeInBackground()
        }
    }

    #if DEBUG
    /// Whether the periodic check is scheduled.
    var synchronizationScheduledForTesting: Bool { synchronizationTimer != nil }

    /// Fires the periodic check as its timer would, then waits for the
    /// synchronization it started, if any.
    func fireSynchronizationTimerForTesting() async {
        synchronizationTimer?.fire()
        await backgroundSynchronization?.value
    }

    /// Waits for the synchronization a create or the timer started, if any.
    func backgroundSynchronizationForTesting() async {
        await backgroundSynchronization?.value
    }
    #endif

    /// The ids of `owner`'s notifications, including those whose `create` has
    /// not finished yet.
    func getAll(owner: Owner) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for entry in entries.values where entry.owner == owner {
            result[entry.notificationID] = true
        }
        return result
    }

    // MARK: - onClicked / onClosed (TASK-247)

    /// One `onClicked` or `onClosed` for an owner, numbered so the context
    /// can acknowledge it.
    struct Event: Equatable {
        /// Increases with every event the manager delivers, to any owner.
        let seq: Int
        let kind: Response.Kind
        let notificationID: String
        /// For a close: whether the user ended it (dismissed or clicked it,
        /// or it left Notification Center), rather than the extension
        /// clearing it.
        let byUser: Bool

        /// What the polyfill dispatches: `{seq, kind, notificationId, byUser?}`.
        var reply: [String: Any] {
            var reply: [String: Any] = ["seq": seq, "notificationId": notificationID]
            switch kind {
            case .clicked:
                reply["kind"] = "clicked"
            case .closed:
                reply["kind"] = "closed"
                reply["byUser"] = byUser
            }
            return reply
        }
    }

    /// How an owner's background context hears about its notifications.
    /// There is no push channel into a context, so the background polyfill
    /// parks a `notifications.awaitEvent` request, answered with the events
    /// it has not acknowledged; it dispatches them and parks again, carrying
    /// the last `seq` it saw as the acknowledgement.
    ///
    /// An event stays in `backlog` until it is acknowledged, not just until
    /// it is answered: a parked reply whose worker WebKit has since unloaded
    /// goes nowhere and nothing says so, and the parked request does not keep
    /// the worker alive (it is a native message, not a port; see the
    /// service-worker-unload-rules wiki). The next incarnation's first park,
    /// which acknowledges nothing, receives it again.
    private struct EventChannel {
        struct Parked {
            let reply: (Any?, String?) -> Void
            let instance: String?
        }
        var parked: Parked?
        /// Events not yet acknowledged, oldest first, at most `eventBacklogLimit`.
        var backlog: [Event] = []
        /// The incarnation tokens that have parked, oldest first, at most
        /// `instanceHistoryLimit`. The last is the current incarnation: one
        /// seen before it is older and may not park again.
        var instances: [String] = []
        /// Whether a background context of the owner has ever parked this
        /// launch, i.e. listens: only then does an event wake it.
        var listens = false
    }

    private var eventChannels: [Owner: EventChannel] = [:]
    private var lastEventSeq = 0

    /// How many unacknowledged events an owner keeps; past it the oldest go.
    static let eventBacklogLimit = 32
    /// How many incarnations of an owner's background are remembered as
    /// superseded.
    static let instanceHistoryLimit = 8

    /// The answer to a park from an incarnation a newer one has superseded.
    static let supersededWaitError = "notifications: superseded by a newer wait"

    /// Starts the owner's background content, so an event reaches a worker
    /// WebKit unloaded: its listeners are added again as its script runs, and
    /// the park that follows drains the backlog. A no-op while it is loaded.
    /// A seam: a test records the wakes instead.
    var wakeBackground: @MainActor (Owner) -> Void = ExtensionNotificationManager.loadBackgroundContent(of:)

    /// The production `wakeBackground`.
    static func loadBackgroundContent(of owner: Owner) {
        guard let profile = TabStore.shared.profiles.first(where: { $0.id == owner.profileID }),
              let context = profile.extensionContext(for: owner.extensionID),
              context.webExtension.hasBackgroundContent else { return }
        let extensionID = owner.extensionID
        context.loadBackgroundContent { error in
            if let error {
                log.error("Waking \(extensionID, privacy: .public) for a notification event failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Parks `reply` for the next events of `owner`'s, or answers at once
    /// with those not yet acknowledged. `ack` is the last `seq` the context
    /// dispatched: it and every earlier one are dropped first. `instance` is
    /// the context's incarnation token (`__detourContextInstance`): a new one
    /// supersedes the park in place, which is answered with
    /// `supersededWaitError`, and from then on an older one is refused the
    /// same way, so an old worker still running alongside its replacement
    /// cannot take the events back. The handler lets only the background
    /// context call this.
    func awaitEvent(owner: Owner, instance: String?, ack: Int?, reply: @escaping (Any?, String?) -> Void) {
        var channel = eventChannels[owner] ?? EventChannel()
        if let instance {
            if let index = channel.instances.firstIndex(of: instance) {
                guard index == channel.instances.count - 1 else {
                    reply(nil, Self.supersededWaitError)
                    return
                }
            } else {
                channel.instances.append(instance)
                if channel.instances.count > Self.instanceHistoryLimit {
                    channel.instances.removeFirst(channel.instances.count - Self.instanceHistoryLimit)
                }
            }
        }
        channel.listens = true
        if let ack { channel.backlog.removeAll { $0.seq <= ack } }
        let previous = channel.parked
        channel.parked = nil
        if channel.backlog.isEmpty {
            channel.parked = EventChannel.Parked(reply: reply, instance: instance)
        }
        let events = channel.backlog
        eventChannels[owner] = channel
        previous?.reply(nil, Self.supersededWaitError)
        if !events.isEmpty { reply(["events": events.map(\.reply)], nil) }
    }

    /// Queues the events, in order, for `owner` and answers the park, if
    /// there is one, with all of them; once the owner listens, also wakes its
    /// background, in case that park belongs to a worker WebKit has unloaded.
    private func deliver(_ events: [(kind: Response.Kind, byUser: Bool)], notificationID: String, to owner: Owner) {
        var channel = eventChannels[owner] ?? EventChannel()
        for event in events {
            lastEventSeq += 1
            channel.backlog.append(Event(seq: lastEventSeq, kind: event.kind, notificationID: notificationID,
                                         byUser: event.byUser))
        }
        if channel.backlog.count > Self.eventBacklogLimit {
            let dropped = channel.backlog.count - Self.eventBacklogLimit
            channel.backlog.removeFirst(dropped)
            log.info("Dropped \(dropped) unacknowledged notification event(s) for extension \(owner.extensionID, privacy: .public)")
        }
        let parked = channel.parked
        channel.parked = nil
        let events = channel.backlog
        let listens = channel.listens
        eventChannels[owner] = channel
        parked?.reply(["events": events.map(\.reply)], nil)
        if listens { wakeBackground(owner) }
    }

    /// Forgets the event channels of the matching owners, answering any park
    /// so its context stops waiting: the extension was unloaded from the
    /// profile, or the profile went away.
    private func dropEventChannels(where matches: (Owner) -> Bool) {
        let dropped = eventChannels.filter { matches($0.key) }
        for (owner, channel) in dropped {
            eventChannels[owner] = nil
            channel.parked?.reply(nil, "notifications: the extension was unloaded")
        }
    }

    #if DEBUG
    /// The owner's unacknowledged events and the instance parked, if any.
    func eventChannelForTesting(_ owner: Owner) -> (backlog: [Event], parkedInstance: String??, listens: Bool) {
        let channel = eventChannels[owner]
        return (channel?.backlog ?? [], channel?.parked.map(\.instance), channel?.listens ?? false)
    }
    #endif

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
    /// by the exact identifier, drops the entry, and delivers the events to
    /// that owner (TASK-247): for a dismissal `onClosed` with `byUser` true,
    /// as a dismissal is the user's (the category's `.customDismissAction` is
    /// what makes the center report one); for a click `onClicked`, then
    /// `onClosed` with `byUser` true (TASK-272). macOS takes a clicked banner
    /// away (Chrome keeps its banner only by setting the private
    /// `shouldPreventNotificationDismissalAfterDefaultAction`, which Detour
    /// does not), and Chrome reports a notification that left Notification
    /// Center unreported as closed by the user; so `getAll` stops listing it
    /// and `clear` and `update` answer false, rather than an update bringing
    /// the banner back. An `add` in flight for it (an update) finds no entry
    /// and takes what it shows away again. Nothing else is touched: the same
    /// id in another profile or extension is a different identifier. An
    /// identifier with no entry — another launch's, an earlier build's, or
    /// one already cleared or clicked — resolves to nil and changes nothing.
    @discardableResult
    func handleResponse(identifier: String, action: String) -> Response? {
        guard let entry = entries[identifier] else { return nil }
        let events: [(kind: Response.Kind, byUser: Bool)]
        if action == UNNotificationDefaultActionIdentifier {
            events = [(.clicked, byUser: false), (.closed, byUser: true)]
            log.info("Notification clicked: \(entry.notificationID, privacy: .private) for extension \(entry.owner.extensionID, privacy: .public)")
            // macOS takes a clicked banner away; in case it kept this one,
            // take it away too, as nothing could once the entry is gone.
            center.removeNotifications(withIdentifiers: [identifier])
        } else if action == UNNotificationDismissActionIdentifier {
            events = [(.closed, byUser: true)]
            log.info("Notification closed: \(entry.notificationID, privacy: .private) for extension \(entry.owner.extensionID, privacy: .public)")
        } else {
            return nil
        }
        removeEntry(identifier: identifier)
        deliver(events, notificationID: entry.notificationID, to: entry.owner)
        return Response(owner: entry.owner, notificationID: entry.notificationID, kind: events[0].kind)
    }
}
