import Foundation
import NaturalLanguage
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-polyfill")

/// Handles native-backed Chrome extension API requests from the JS polyfills.
/// Registered as a `WKScriptMessageHandlerWithReply` on the extension controller's
/// web view configuration, so all extension contexts (background, popup, content)
/// can send messages and receive async responses.
///
/// One handler belongs to one `Profile`: the profile builds it in
/// `extensionController` and is the only thing that knows which extension owns
/// which `webkit-extension://` origin, so senders are attributed through
/// `profile.extensionID(forOriginScheme:host:)` and contexts (offscreen
/// documents) resolved through `profile.extensionContext(for:)`. The reference
/// is weak: the profile owns the handler. A released profile attributes
/// nothing, so every web-view message is rejected — the body's `extensionID`
/// is never trusted as a fallback.
class ExtensionPolyfillHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "detourPolyfill"

    /// The message type the polyfill uses to have WebKit set
    /// `runtime.lastError` for a failed callback-style call (TASK-23).
    static let lastErrorRelayType = "runtime.lastErrorRelay"

    /// A worker's polyfill request sets `errorEnvelope: true`, and a failure
    /// is then answered as a successful reply `{ errorEnvelopeKey: text }`
    /// rather than an error: WebKit rewrites any error crossing
    /// `runtime.sendNativeMessage` ("Invalid call to
    /// runtime.sendNativeMessage(). <Text>."), and the polyfill rejects with
    /// the text exactly as a page would see it (TASK-255).
    static let errorEnvelopeKey = "__detourPolyfillError"

    /// On the same requests a success is wrapped too, as
    /// `{ successEnvelopeKey: true, successEnvelopeValueKey: result }` (the
    /// value key left out for a nil result), so a handler result that happens
    /// to carry `errorEnvelopeKey` is never read as a failure (TASK-262).
    static let successEnvelopeKey = "__detourPolyfillOk"
    static let successEnvelopeValueKey = "value"

    /// Answers a failed native-message request from a worker: as the
    /// `errorEnvelopeKey` reply when the request asked for it, otherwise as
    /// an error (which WebKit rewrites).
    static func replyFailure(_ text: String, to body: [String: Any],
                             replyHandler: (Any?, (any Error)?) -> Void) {
        if body["errorEnvelope"] as? Bool == true {
            replyHandler([errorEnvelopeKey: text], nil)
        } else {
            replyHandler(nil, NSError(domain: "DetourPolyfill", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: text]))
        }
    }

    /// Answers a successful native-message request from a worker: wrapped in
    /// the success envelope when the request asked for envelopes, otherwise
    /// as the bare result.
    static func replySuccess(_ result: Any?, to body: [String: Any],
                             replyHandler: (Any?, (any Error)?) -> Void) {
        guard body["errorEnvelope"] as? Bool == true else {
            replyHandler(result, nil)
            return
        }
        var envelope: [String: Any] = [successEnvelopeKey: true]
        if let result { envelope[successEnvelopeValueKey] = result }
        replyHandler(envelope, nil)
    }

    /// Longest relayed lastError message, in characters.
    static let lastErrorRelayMessageLimit = 2048

    /// The answer to a `notifications.*` request whose profile has been
    /// released, so no owner can be named for it.
    static let notificationsProfileGone = "notifications: the profile is gone"

    /// The profile whose extension controller this handler serves.
    private(set) weak var profile: Profile?

    init(profile: Profile) {
        self.profile = profile
        self.profileID = profile.id
        super.init()
    }

    /// The history database `history.search` reads, as a test seam: the request
    /// arrives from a real extension context, so an integration test has no
    /// call site to hand a database to. Production never assigns it. Which
    /// rows of it a request may see is decided per request, from `profile`.
    var historyDatabase: HistoryDatabase = .shared

    /// The clock `history.search` measures its default range from (TASK-153)
    /// and the permission gates read grant and denial expiry against
    /// (TASK-277), as a test seam for the same reason. Production never
    /// assigns it.
    var now: () -> Date = Date.init

    /// The manager behind `notifications.*`, as a test seam for the same
    /// reason: a test hands it a fake notification center (TASK-234), and
    /// hands the same one to two profiles' handlers to check they stay apart
    /// (TASK-238). Production never assigns it, and a test sets it back to nil.
    var notificationManagerOverride: ExtensionNotificationManager?

    /// One manager for every profile; requests are scoped by `profile` (see
    /// `notificationOwner`). Read at the first notification call, so the
    /// shared manager (and with it the system center's delegate) is not set
    /// up when a profile builds its handler.
    private var notificationManager: ExtensionNotificationManager {
        notificationManagerOverride ?? .shared
    }

    /// Who a `notifications.*` request acts for: this handler's profile and the
    /// verified extension id. Once the profile is gone there is no owner to
    /// name, so this answers the request with `notificationsProfileGone` and
    /// returns nil.
    private func notificationOwner(_ extensionID: String,
                                   orRefuse replyHandler: (Any?, String?) -> Void) -> ExtensionNotificationManager.Owner? {
        guard profile != nil else {
            replyHandler(nil, Self.notificationsProfileGone)
            return nil
        }
        return ExtensionNotificationManager.Owner(profileID: profileID, extensionID: extensionID)
    }

    /// Whether `extensionID` holds the `notifications` permission — declared,
    /// or optional and granted (TASK-250) — as Chrome gates the namespace
    /// (TASK-239). A decision is the extension's, not the profile's: Detour
    /// applies it to every profile's context, the Private one included
    /// (`ExtensionManager.setPermissionDecision`); this reads it from this
    /// profile's context. If not, answers the request with the refusal and
    /// returns false.
    private func notificationsPermitted(_ extensionID: String,
                                        orRefuse replyHandler: (Any?, String?) -> Void) -> Bool {
        if let refusal = permissionRefusal("notifications", extensionID: extensionID) {
            replyHandler(nil, refusal)
            return false
        }
        return true
    }

    /// This handler's profile id: every owner it names. Kept rather than read
    /// from `profile`, because the removals below run while the profile is
    /// being torn down.
    private let profileID: UUID

    /// The manager whose notifications a removal takes away: the override, or
    /// the shared one only if something created it this launch (otherwise
    /// there is nothing to remove, and the system center stays untouched).
    private var existingNotificationManager: ExtensionNotificationManager? {
        notificationManagerOverride ?? .sharedIfCreated
    }

    /// Takes away the notifications `extensionID` created in this profile.
    /// `Profile.unloadExtension` calls it: a context that is gone cannot hear
    /// about them or clear them, and a reloaded one starts with none.
    func removeNotifications(ofExtension extensionID: String) {
        existingNotificationManager?.removeAll(
            for: ExtensionNotificationManager.Owner(profileID: profileID, extensionID: extensionID))
    }

    /// Takes away the notifications `extensionID` created in this profile, and
    /// answers its wait for their events with the permission refusal, when
    /// `notifications` is not active in this profile's context any more
    /// (TASK-270): the Settings switch turned off, or `permissions.remove` of
    /// the optional permission. Either decision is the extension's and reaches
    /// every profile's context, so `ExtensionManager` calls this for every
    /// profile after a permission decision changes; while the permission is
    /// active it does nothing. It writes no permission.
    func revokeNotificationsIfNotPermitted(ofExtension extensionID: String) {
        guard let manager = existingNotificationManager,
              let refusal = permissionRefusal("notifications", extensionID: extensionID) else { return }
        manager.revoke(for: ExtensionNotificationManager.Owner(profileID: profileID, extensionID: extensionID),
                       refusal: refusal)
    }

    /// Takes away every extension's notifications in this profile when the
    /// profile is deleted, and stops its contexts' waits for their events.
    func removeAllNotifications() {
        existingNotificationManager?.removeAll(profileID: profileID)
    }

    /// Takes away every extension's notifications in this profile, and the
    /// events queued for them, at a Private session boundary
    /// (`TabStore.removePrivateProfileNotifications`: a session starting or
    /// ending, or the app quitting), so none carries over into the next one.
    /// The contexts stay loaded across it, so their waits for events stand
    /// (TASK-264).
    func removeSessionNotifications() {
        existingNotificationManager?.removeSession(profileID: profileID)
    }

    /// Active offscreen document hosts, keyed by extensionID.
    var offscreenHosts: [String: OffscreenDocumentHost] = [:]

    /// Stop and forget the extension's offscreen document, if any. The single
    /// teardown for `offscreen.closeDocument` and for context unload
    /// (`Profile.unloadExtension`), so both release the hidden web view. A
    /// `createDocument` still loading is settled by `stop()` failing its
    /// completion with `.closedBeforeLoad`; the completion also sees the host is
    /// no longer registered, so it can never report a document that is gone.
    /// Unregister before stopping, in that order, for exactly that reason.
    func closeOffscreenDocument(for extensionID: String) {
        guard let host = offscreenHosts.removeValue(forKey: extensionID) else { return }
        host.stop()
    }

    /// The reply for one `offscreen.createDocument` request, run when `host`'s
    /// load settles. Shared by the request that started the load and by any
    /// request that joined it while it was in flight, so every waiter sees the
    /// same outcome and the failure teardown runs once.
    ///
    /// The load settles exactly once, one of three ways: it finished, it
    /// failed, or `stop()` ran first (an explicit closeDocument or a context
    /// unload). The request must settle either way, and must never report a
    /// document that is gone.
    private func offscreenLoadCompletion(
        extensionID: String, host: OffscreenDocumentHost,
        replyHandler: @escaping (Any?, String?) -> Void
    ) -> (Result<Void, any Error>) -> Void {
        return { [weak self, weak host] result in
            // The identity check is what keeps a late reply off a newer
            // document: by the time this runs the registered host may be a
            // second one built by a later createDocument, and neither a
            // success nor a failure belonging to the dead host may touch it.
            // A waiter that joined the load runs after the first completion
            // has already torn a failed host down and lands here too; it
            // reports the failure it actually waited on.
            guard let self, let host, self.offscreenHosts[extensionID] === host else {
                if case .failure(let error) = result {
                    log.info("offscreen.createDocument: failed for \(extensionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    replyHandler(nil, error.localizedDescription)
                } else {
                    log.info("offscreen.createDocument: closed before it finished loading for \(extensionID, privacy: .public)")
                    replyHandler(nil, OffscreenDocumentHost.LoadError.closedBeforeLoad.localizedDescription)
                }
                return
            }
            switch result {
            case .success:
                log.info("offscreen.createDocument: loaded successfully for \(extensionID, privacy: .public)")
                replyHandler(true, nil)
            case .failure(let error):
                // The host is still the registered one (checked above) but
                // its document never loaded, so drop it: leaving it in place
                // would make hasDocument lie and short-circuit every later
                // createDocument with success (TASK-18).
                self.closeOffscreenDocument(for: extensionID)
                log.error("offscreen.createDocument: load failed for \(extensionID, privacy: .public), host unregistered: \(error.localizedDescription, privacy: .public)")
                replyHandler(nil, error.localizedDescription)
            }
        }
    }

    /// The fixed polyfill envelope keys (see `__detourPolyfillRequest` in
    /// ExtensionAPIPolyfill). Diagnostics log only these names: any other key
    /// in a body is extension-authored text and stays out of the log, as do
    /// all values.
    private static let envelopeKeys: Set<String> = ["type", "extensionID", "params"]

    /// Log-safe shape of a malformed body: which envelope keys are present,
    /// how many foreign keys there are, and the Swift type of `type` (so a
    /// present-but-non-String `type` is distinguishable from an absent one).
    private static func envelopeSummary(_ body: [String: Any]) -> String {
        let known = body.keys.filter { envelopeKeys.contains($0) }.sorted()
        let foreign = body.count - known.count
        let typeKind = body["type"].map { String(describing: Swift.type(of: $0)) } ?? "absent"
        return "envelope keys \(known), \(foreign) other, type: \(typeKind)"
    }

    /// UserDefaults key that opts the extension console bridge into logging
    /// message text publicly (persisted, visible to `log show`/`log stream`).
    /// Off by default because extension console output can contain secrets.
    /// Enable for one debugging session with
    /// `defaults write com.detourbrowser.mac ExtensionConsoleLogPublic -bool YES`
    /// and disable again with `defaults delete com.detourbrowser.mac ExtensionConsoleLogPublic`.
    /// Read once per launch so a session is consistently one or the other.
    static let consoleLogPublicDefaultsKey = "ExtensionConsoleLogPublic"
    private static let consoleLogIsPublic: Bool = {
        let enabled = UserDefaults.standard.bool(forKey: consoleLogPublicDefaultsKey)
        if enabled {
            log.notice("Extension console bridge is logging message text PUBLICLY (\(consoleLogPublicDefaultsKey, privacy: .public) is set); extension console output may contain secrets")
        }
        return enabled
    }()

    /// Per-extension cap on forwarded console messages (TASK-17). Per handler, so
    /// per profile; keyed by the *verified* extension id, never a claimed one.
    private var consoleLimiter = ConsoleBridgeLimiter()

    /// Drop the extension's console rate-limit window, for context unload
    /// (`Profile.unloadExtension`). A reloaded context gets a fresh burst.
    func forgetConsoleRateLimit(for extensionID: String) {
        consoleLimiter.forget(extensionID)
    }

    // MARK: - Sender

    /// How a polyfill request reached the handler, for the few requests that
    /// are background-context-only (TASK-64).
    enum PolyfillSender: Equatable {
        /// `runtime.sendNativeMessage` from a `WKWebExtensionContext`: no frame.
        case nativeMessage
        /// `webkit.messageHandlers` from a web view frame. `isDetourHosted` is
        /// whether the sending web view is one Detour created or presented
        /// (`ExtensionPageHostRegistry`) — a tab, the action popup, an options
        /// page or an offscreen document. Only WebKit's background page runs in
        /// a web view the host never touched, so `false` is what a background
        /// frame looks like (TASK-66).
        case frame(url: URL?, isMainFrame: Bool, isDetourHosted: Bool)

        /// For the log. A frame's path is in the extension's own bundle, so it
        /// is as public as the extension id.
        var logDescription: String {
            switch self {
            case .nativeMessage:
                return "native message"
            case .frame(let url, let isMainFrame, let isDetourHosted):
                return "\(isDetourHosted ? "detour-hosted" : "unhosted") frame at \(url.flatMap(Self.percentEncodedPath) ?? "(no url)") (main frame: \(isMainFrame))"
            }
        }

        /// The URL's path as WebKit serves it — percent-encoded, which is what
        /// the polyfill compares too (`location.pathname`), so both gates see
        /// one spelling of a path.
        static func percentEncodedPath(_ url: URL) -> String? {
            URLComponents(url: url.standardized, resolvingAgainstBaseURL: false)?.percentEncodedPath
        }
    }

    /// WebKit's path for the page it generates to host a `background.scripts`
    /// list, relative to the context's base URL (measured for TASK-43; the
    /// polyfill's `preambleJS` hardcodes the same path).
    static let generatedBackgroundPagePath = "/_generated_background_page.html"

    /// The (percent-encoded) path the extension's background *document* loads
    /// at, or nil when the manifest declares no document shape. `page` wins over
    /// `scripts` when both are declared, as in the polyfill.
    private static func backgroundDocumentPath(_ background: ExtensionManifest.Background) -> String? {
        if let page = background.page, !page.isEmpty {
            // Resolved against the extension *root*, because that is what a
            // manifest path is relative to: Chrome accepts './bg.html' and
            // 'my page.html', which WebKit loads at '/bg.html' and
            // '/my%20page.html'. The host is a placeholder — only the path is
            // compared, and the sender's origin was already attributed to this
            // extension by the entry point.
            guard let root = extensionOriginBaseURL(host: "x"),
                  let resolved = URL(string: page, relativeTo: root)?.absoluteURL else { return nil }
            // An absolute URL pointing somewhere else is not this extension's
            // background page, whatever its path looks like.
            guard isExtensionPage(resolved, ofOriginHost: "x") else { return nil }
            return PolyfillSender.percentEncodedPath(resolved)
        }
        if background.mayRunInGeneratedPage {
            return generatedBackgroundPagePath
        }
        return nil
    }

    /// Whether `sender` is the extension's background context, the only context
    /// allowed to claim `runtime.onInstalled` (TASK-64). Mirrors the polyfill's
    /// own `contextKind` decision (ExtensionAPIPolyfill `preambleJS`): a frame
    /// sender must be the top-level document at the background document's
    /// path; a native-message sender (no frame: the worker's only transport)
    /// is accepted when the manifest's background may run as a service worker.
    /// Fails closed for a manifest with no background content.
    ///
    /// A frame's path alone would not be enough — a tab or popup *navigated to*
    /// the background path (`location.href = '/bg.html'`) has that path too, and
    /// the polyfill classifies such a page as a background context as well. The
    /// host can tell them apart because `ExtensionPageHostRegistry` holds every
    /// web view Detour creates or presents, while WebKit's background page is
    /// the one view a loaded context runs that Detour never touches: so a
    /// Detour-hosted frame is refused whatever its path (TASK-66).
    ///
    /// Known limit, inherent to what WebKit tells the host:
    /// `runtime.sendNativeMessage` reaches the host with the context only, never
    /// the sending frame or its web view, so for a service-worker manifest an
    /// ordinary extension page that calls it directly is indistinguishable from
    /// the worker. It can only take its *own* extension's event.
    static func senderIsBackgroundContext(_ sender: PolyfillSender,
                                          background: ExtensionManifest.Background?) -> Bool {
        guard let background else { return false }
        switch sender {
        case .nativeMessage:
            return background.mayRunAsServiceWorker
        case .frame(let url, let isMainFrame, let isDetourHosted):
            // A view Detour hosts is a tab, popup, options page or offscreen
            // document — user-facing extension content, never the background
            // page, however it was navigated.
            guard !isDetourHosted else { return false }
            // Only the top-level document qualifies: an extension page can
            // iframe the background page's own path, and that iframe must not
            // pass for the real background context.
            guard isMainFrame, let url,
                  let documentPath = backgroundDocumentPath(background) else { return false }
            return PolyfillSender.percentEncodedPath(url) == documentPath
        }
    }

    // MARK: - chrome.permissions for permissions WebKit does not know (TASK-260)

    /// Chromium's refusal of a `permissions.request` naming a permission the
    /// manifest lists in neither `permissions` nor `optional_permissions`.
    static let permissionRequestNotInManifestError = "Only permissions specified in the manifest may be requested."

    /// Chromium's refusal of a `permissions.remove` naming a permission the
    /// manifest does not list.
    static let permissionRemoveNotInManifestError = "Only permissions specified in the manifest may be removed."

    /// Chromium's refusal of a `permissions.remove` naming a required permission.
    static let permissionRemoveRequiredError = "You cannot remove required permissions."

    /// The `permissions` of a `permissions.*` request from the polyfill's
    /// wrapper: a non-empty array of names in
    /// `WebExtension.permissionsOutsideWebKit`, without repeats. Anything else
    /// is refused: the wrapper sends WebKit's own names to WebKit, and a
    /// request made past it gets no other name answered here.
    static func outsideWebKitPermissionNames(from params: [String: Any]) -> Result<[String], PolyfillArgumentError> {
        guard let raw = params["permissions"] as? [Any], !raw.isEmpty else {
            return .failure(PolyfillArgumentError(message: "permissions: a non-empty permissions array is required"))
        }
        var names: [String] = []
        for value in raw {
            guard let name = value as? String, WebExtension.permissionsOutsideWebKit.contains(name) else {
                return .failure(PolyfillArgumentError(
                    message: "permissions: \(value) is not a permission Detour answers for"))
            }
            if !names.contains(name) { names.append(name) }
        }
        return .success(names)
    }

    /// What a `permissions.request` of `names` does, before anyone is asked.
    enum PermissionRequestPlan: Equatable {
        /// Refused with this message: a name the manifest does not list.
        case refuse(String)
        /// Answered without a prompt: true when every name is already held,
        /// false when one is required but switched off in Settings, or denied.
        case answer(Bool)
        /// Prompt for these names: optional, undecided and not held.
        case prompt([String])
    }

    /// Chrome's rule for which names a request may carry: only manifest
    /// names (a required one is granted already, so it counts as held). A
    /// held name needs no prompt. A denied name, and a required one switched
    /// off in Settings, make the request answer false without asking, as
    /// WebKit answers a request for a permission it holds as denied: only the
    /// Settings switch turns those back on.
    static func permissionRequestPlan(_ names: [String], manifest: ExtensionManifest,
                                      context: WKWebExtensionContext?, now: Date = Date()) -> PermissionRequestPlan {
        // Every name is checked against the manifest before any is answered,
        // as in Chrome: a denied name must not hide an undeclared one.
        for name in names where manifest.permissions?.contains(name) != true
            && manifest.optionalPermissions?.contains(name) != true {
            return .refuse(permissionRequestNotInManifestError)
        }
        var undecided: [String] = []
        for name in names {
            let required = manifest.permissions?.contains(name) == true
            if permissionIsActive(name, manifest: manifest, context: context, now: now) { continue }
            let key = WKWebExtension.Permission(rawValue: name)
            if required { return .answer(false) }
            if let deniedUntil = context?.deniedPermissions[key], deniedUntil > now { return .answer(false) }
            undecided.append(name)
        }
        return undecided.isEmpty ? .answer(true) : .prompt(undecided)
    }

    /// Chrome's refusal of a `permissions.remove` of `names`, or nil when
    /// each is optional: not one the manifest lists, or a required one.
    static func permissionRemovalRefusal(_ names: [String], manifest: ExtensionManifest) -> String? {
        for name in names {
            if manifest.permissions?.contains(name) == true { return permissionRemoveRequiredError }
            if manifest.optionalPermissions?.contains(name) != true { return permissionRemoveNotInManifestError }
        }
        return nil
    }

    /// Chrome's `runtime.requestUpdateCheck` answer for an updater outcome.
    /// An extension that cannot update, and a check that failed, both read as
    /// `no_update` — Chrome reports no error for either. An update Detour just
    /// installed (even one held for permission approval) is `update_available`.
    static func requestUpdateCheckReply(for outcome: ExtensionUpdateOutcome) -> [String: Any] {
        switch outcome {
        case .throttled:
            return ["status": "throttled"]
        case .upToDate, .notUpdatable, .failed:
            return ["status": "no_update"]
        case .updated(let version), .updatedPendingPermissions(let version, _), .deferred(let version):
            return ["status": "update_available", "version": version]
        }
    }

    // MARK: - chrome.history arguments

    /// A `chrome.history.search` query that passed validation (TASK-138), with
    /// Chrome's defaults applied.
    nonisolated struct HistorySearchQuery: Equatable, Sendable {
        var text: String
        var maxResults: Int
        /// Seconds since 1970, as the history database stores visit times
        /// (the extension sends milliseconds). The range is half-open,
        /// `[startTime, endTime)`; nil is no bound on that side.
        var startTime: Double?
        var endTime: Double?
    }

    /// Why a polyfill request's arguments were refused; `message` is what the
    /// extension sees as the rejection and as `runtime.lastError`.
    struct PolyfillArgumentError: Error, Equatable {
        let message: String
    }

    /// Chrome's `maxResults` default.
    static let historySearchDefaultMaxResults = 100

    /// Chrome's `startTime` default (TASK-153): a query that names none covers
    /// the 24 hours before now.
    static let historySearchDefaultRange: TimeInterval = 24 * 3600

    /// Validate the `query` of a `history.search` request.
    ///
    /// Chrome throws on a malformed query; here the request is refused, which
    /// the polyfill turns into a rejected promise or `runtime.lastError`. A
    /// lenient parse is not an option: reading a missing `text` as "" answered
    /// a malformed call with the whole history.
    ///
    /// `text` is required and must be a string. `maxResults`, `startTime` and
    /// `endTime` are optional — absent and `null` are the same — and must be
    /// numbers (a boolean is not one, though it arrives as an `NSNumber`):
    /// `maxResults` a non-negative integer, the times finite. Whether a number
    /// arrives as an integer or a double depends on the transport, so both
    /// are accepted.
    ///
    /// The range follows Chrome (TASK-153). With no `startTime` it begins 24
    /// hours before `now`, whatever `text`, `maxResults` and `endTime` say —
    /// Chrome sets its default range first and then overwrites each bound the
    /// query gives (`HistorySearchFunction` in `history_api.cc`). That is also
    /// what keeps the common call cheap: `search({ text: '' })`, which a
    /// new-tab page makes on every open, reads a day and not the profile's
    /// whole history. A `startTime` that is given is taken as given, and 0 is
    /// how an extension asks for everything, so 0 (or less: nothing was
    /// visited before 1970) is no lower bound at all rather than a bound for
    /// the query to compare every visit with. An omitted `endTime` stays no
    /// upper bound; Chrome's is "now", which differs only for a visit dated in
    /// the future.
    static func historySearchQuery(from params: [String: Any],
                                   now: Date) -> Result<HistorySearchQuery, PolyfillArgumentError> {
        func refuse(_ what: String) -> Result<HistorySearchQuery, PolyfillArgumentError> {
            .failure(PolyfillArgumentError(message: "history.search: \(what)"))
        }
        /// An optional member: nil when absent or null.
        func member(_ name: String, of query: [String: Any]) -> Any? {
            guard let value = query[name], !(value is NSNull) else { return nil }
            return value
        }
        func number(_ value: Any) -> Double? {
            guard let boxed = value as? NSNumber, CFGetTypeID(boxed) != CFBooleanGetTypeID(),
                  boxed.doubleValue.isFinite else { return nil }
            return boxed.doubleValue
        }

        guard let query = params["query"] as? [String: Any] else {
            return refuse("query must be an object")
        }
        guard let text = query["text"] as? String else {
            return refuse("query.text must be a string")
        }

        var parsed = HistorySearchQuery(text: text, maxResults: historySearchDefaultMaxResults,
                                        startTime: now.timeIntervalSince1970 - historySearchDefaultRange)
        if let raw = member("maxResults", of: query) {
            guard let value = number(raw), value >= 0, value == value.rounded() else {
                return refuse("query.maxResults must be a non-negative integer")
            }
            parsed.maxResults = Int(min(value, Double(Int32.max)))
        }
        if let raw = member("startTime", of: query) {
            guard let value = number(raw) else { return refuse("query.startTime must be a number") }
            parsed.startTime = value > 0 ? value / 1000.0 : nil
        }
        if let raw = member("endTime", of: query) {
            guard let value = number(raw) else { return refuse("query.endTime must be a number") }
            parsed.endTime = value / 1000.0
        }
        return .success(parsed)
    }

    /// `management.getPermissionWarningsByManifest(manifestStr)` (TASK-257):
    /// the lines Detour's install prompt lists for the manifest — its required
    /// permissions and its site access, not what it may request later — as
    /// `ExtensionPermissionDescriptions.warnings` gives them. That is not
    /// Chrome's list: Chrome leaves out permissions that carry no warning
    /// (`storage`, `alarms`) and merges hosts, where Detour's prompt names
    /// every permission. The refusals use Chromium's texts
    /// (`management_api_constants.h`), except that malformed JSON reads
    /// `kManifestParseError` rather than the JSON parser's own message.
    static func permissionWarnings(from params: [String: Any]) -> Result<[String], PolyfillArgumentError> {
        guard let manifestString = params["manifestStr"] as? String else {
            return .failure(PolyfillArgumentError(
                message: "management.getPermissionWarningsByManifest: manifestStr must be a string"))
        }
        let data = Data(manifestString.utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            return .failure(PolyfillArgumentError(message: "Failed to parse manifest."))
        }
        guard let manifest = try? JSONDecoder().decode(ExtensionManifest.self, from: data) else {
            return .failure(PolyfillArgumentError(message: "Failed to create extension from manifest."))
        }
        return .success(ExtensionPermissionDescriptions.warnings(
            permissions: manifest.permissions ?? [], hostPermissions: manifest.hostPermissions ?? []))
    }

    /// `management.uninstallSelf(options)`'s `showConfirmDialog`: `options`
    /// absent or null, or an object whose `showConfirmDialog` is absent, null
    /// or a boolean. Anything else is refused, as Chrome's schema check does.
    static func uninstallSelfShowsConfirmDialog(from params: [String: Any]) -> Result<Bool, PolyfillArgumentError> {
        guard let raw = params["options"], !(raw is NSNull) else { return .success(false) }
        guard let options = raw as? [String: Any] else {
            return .failure(PolyfillArgumentError(message: "management.uninstallSelf: options must be an object"))
        }
        guard let flag = options["showConfirmDialog"], !(flag is NSNull) else { return .success(false) }
        guard let boxed = flag as? NSNumber, CFGetTypeID(boxed) == CFBooleanGetTypeID() else {
            return .failure(PolyfillArgumentError(
                message: "management.uninstallSelf: options.showConfirmDialog must be a boolean"))
        }
        return .success(boxed.boolValue)
    }

    /// Chrome's `HistoryItem` for one URL of the calling profile's history.
    private static func historyItem(_ entry: HistoryURLEntry) -> [String: Any] {
        [
            "id": String(entry.urlID),
            "url": entry.url,
            // The profile may have no title it can show for the URL: the visit
            // was recorded without one, or only title-less visits remain and
            // the shared title may be another profile's (TASK-91, TASK-138).
            // Chrome's history items always carry something displayable, so
            // fall back to the URL rather than handing back an empty string.
            "title": entry.title.isEmpty ? entry.url : entry.title,
            "lastVisitTime": entry.lastVisitTime * 1000.0,
            "visitCount": entry.visitCount,
            "typedCount": entry.typedCount,
        ]
    }

    // MARK: - Entry Points

    /// Entry point for web view contexts (popup, options) via WKScriptMessageHandlerWithReply.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any] else {
            replyHandler(nil, "Invalid message format")
            return
        }
        // The body id is never a fallback: any page reaching this handler can
        // put any string in the body, so an unverifiable origin is rejected
        // rather than trusted.
        let origin = message.frameInfo.securityOrigin
        guard let verifiedExtensionID = verifiedExtensionID(for: origin) else {
            logRejectedOrigin(origin, type: body["type"] as? String)
            replyHandler(nil, "Unrecognized extension origin")
            return
        }
        dispatch(body, verifiedExtensionID: verifiedExtensionID,
                 sender: .frame(url: message.frameInfo.request.url,
                                isMainFrame: message.frameInfo.isMainFrame,
                                // A message with no web view cannot be shown to
                                // be WebKit's untouched background view, so it
                                // fails closed as hosted (TASK-66).
                                isDetourHosted: message.webView.map(ExtensionPageHostRegistry.isDetourHosted) ?? true),
                 replyHandler: replyHandler)
    }

    /// The trustworthy extension identity for a message from an extension web
    /// view (popup/options/offscreen), derived from the frame's security origin
    /// rather than the self-reported body field. Extension pages load from the
    /// context's `baseURL` (`webkit-extension://<UUID>/`), and WebKit assigns
    /// that UUID afresh every time a context is loaded, independent of the
    /// context's `uniqueIdentifier`; only the profile that loaded the context
    /// knows which extension currently owns the origin, hence the lookup
    /// through the owning profile. Returns nil when the origin is not served by
    /// any extension loaded in this profile, and when the profile is gone.
    private func verifiedExtensionID(for origin: WKSecurityOrigin) -> String? {
        profile?.extensionID(forOriginScheme: origin.protocol, host: origin.host)
    }

    /// Origins already reported as unrecognized, so a page that keeps posting
    /// (every `console.log` goes through the bridge, and the polyfill swallows
    /// the rejection) costs one log line rather than one per message. Bounded
    /// because an extension tab navigated to ordinary web content would
    /// otherwise grow it by one entry per site visited.
    private var reportedUnrecognizedOrigins = Set<String>()
    private static let reportedUnrecognizedOriginsLimit = 64

    private func logRejectedOrigin(_ origin: WKSecurityOrigin, type: String?) {
        // The origin is not an extension's, so its host may be a site the user
        // is browsing (an extension tab navigated away, or a remote iframe in
        // an extension page): the scheme is public, the host is not.
        let key = "\(origin.protocol)://\(origin.host):\(origin.port)"
        if reportedUnrecognizedOrigins.contains(key) {
            log.debug("Rejecting polyfill message \(type ?? "(unknown)", privacy: .public) from already-reported unrecognized origin \(key, privacy: .private)")
            return
        }
        if reportedUnrecognizedOrigins.count >= Self.reportedUnrecognizedOriginsLimit {
            reportedUnrecognizedOrigins.removeAll()
        }
        reportedUnrecognizedOrigins.insert(key)
        log.error("Rejecting polyfill message \(type ?? "(unknown)", privacy: .public) from unrecognized \(origin.protocol, privacy: .public) origin \(key, privacy: .private); further messages from it are logged at debug")
    }

    /// Entry point for service worker contexts via browser.runtime.sendNativeMessage.
    /// Called by ExtensionManager's delegate when appID == "detourPolyfill".
    /// `verifiedExtensionID` is derived from the sending `WKWebExtensionContext`;
    /// the delegate rejects messages whose context it cannot attribute before
    /// they reach here, so the body id is never a fallback on this path either.
    func handleNativeMessage(_ body: [String: Any], verifiedExtensionID: String, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        let type = body["type"] as? String ?? "(unknown)"
        log.debug("Native message bridge: \(type, privacy: .public)")
        dispatch(body, verifiedExtensionID: verifiedExtensionID, sender: .nativeMessage) { result, errorString in
            if let errorString, type == Self.lastErrorRelayType {
                // The relay fails by design, and the original failure was
                // already logged where it happened; its text is extension-
                // supplied, so keep it private and out of the error log.
                log.debug("lastError relay: \(errorString, privacy: .private)")
                replyHandler(nil, NSError(domain: "DetourPolyfill", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: errorString]))
            } else if let errorString {
                log.error("Polyfill error for \(type, privacy: .public): \(errorString, privacy: .public)")
                Self.replyFailure(errorString, to: body, replyHandler: replyHandler)
            } else {
                log.debug("Polyfill success for \(type, privacy: .public)")
                Self.replySuccess(result, to: body, replyHandler: replyHandler)
            }
        }
    }

    // MARK: - Dispatch

    /// `verifiedExtensionID` is the sender's identity as established by the
    /// entry point (frame origin for web views, `WKWebExtensionContext` for
    /// workers); both entry points reject before calling this when they cannot
    /// establish one, so the body's `extensionID` is never trusted. `sender` is
    /// how the request arrived (a frame, or the worker's native-message
    /// bridge), which the background-context-only requests need on top of the
    /// identity (TASK-64).
    private func dispatch(_ body: [String: Any], verifiedExtensionID extensionID: String,
                          sender: PolyfillSender, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let type = body["type"] as? String else {
            // Values and foreign key names are extension data (storage values,
            // message payloads) that must not land in the log.
            log.error("Invalid polyfill message: missing or non-string type (\(Self.envelopeSummary(body), privacy: .public))")
            replyHandler(nil, "Invalid message format: missing type")
            return
        }

        // Traffic from the background context is the one sign Detour has that
        // its worker is running; an update waits while it is (TASK-123).
        if Self.senderIsBackgroundContext(sender, background: ExtensionManager.shared.extension(withID: extensionID)?.manifest.background) {
            ExtensionManager.shared.noteBackgroundActivity(extensionID: extensionID)
        }

        // A self-reported id that disagrees with the verified one means the
        // caller is impersonating another extension — reject it. The polyfill
        // stamps an empty string when `chrome.runtime.id` is unavailable in its
        // frame; that carries no claim, so it is not a mismatch.
        if let claimedID = body["extensionID"] as? String, !claimedID.isEmpty, claimedID != extensionID {
            log.error("Extension \(extensionID, privacy: .public) attempted to act as \(claimedID, privacy: .public); rejecting")
            replyHandler(nil, "Extension identity mismatch")
            return
        }

        log.debug("Polyfill request: \(type, privacy: .public) from \(extensionID, privacy: .public)")
        let params = body["params"] as? [String: Any] ?? [:]

        switch type {
        // MARK: - Idle
        case "idle.queryState":
            let interval = params["detectionIntervalInSeconds"] as? Int ?? 60
            let state = IdleMonitor.shared.queryState(detectionIntervalSeconds: interval)
            replyHandler(state, nil)

        case "idle.setDetectionInterval":
            let interval = params["intervalInSeconds"] as? Int ?? 60
            IdleMonitor.shared.setDetectionInterval(interval, for: extensionID)
            replyHandler(true, nil)

        // MARK: - Notifications
        // Gated on the manifest's `notifications` permission, as Chrome gates
        // the namespace (TASK-239), and scoped by this handler's profile as
        // well as the extension: the same extension in another profile,
        // Private included, is another owner (TASK-238).
        case "notifications.create":
            guard notificationsPermitted(extensionID, orRefuse: replyHandler) else { return }
            guard let owner = notificationOwner(extensionID, orRefuse: replyHandler) else { return }
            let notificationId = params["notificationId"] as? String
            let options = params["options"] as? [String: Any] ?? [:]
            notificationManager.create(owner: owner, notificationID: notificationId, options: options) { id in
                replyHandler(["notificationId": id], nil)
            }

        case "notifications.update":
            guard notificationsPermitted(extensionID, orRefuse: replyHandler) else { return }
            guard let notificationId = params["notificationId"] as? String else {
                replyHandler(nil, "notificationId required")
                return
            }
            guard let owner = notificationOwner(extensionID, orRefuse: replyHandler) else { return }
            let options = params["options"] as? [String: Any] ?? [:]
            notificationManager.update(owner: owner, notificationID: notificationId, options: options) { updated in
                replyHandler(["wasUpdated": updated], nil)
            }

        case "notifications.clear":
            guard notificationsPermitted(extensionID, orRefuse: replyHandler) else { return }
            guard let notificationId = params["notificationId"] as? String else {
                replyHandler(nil, "notificationId required")
                return
            }
            guard let owner = notificationOwner(extensionID, orRefuse: replyHandler) else { return }
            notificationManager.clear(owner: owner, notificationID: notificationId) { cleared in
                replyHandler(["wasCleared": cleared], nil)
            }

        case "notifications.getAll":
            guard notificationsPermitted(extensionID, orRefuse: replyHandler) else { return }
            guard let owner = notificationOwner(extensionID, orRefuse: replyHandler) else { return }
            replyHandler(notificationManager.getAll(owner: owner), nil)

        case "notifications.awaitEvent":
            // The background polyfill parks this for `onClicked` / `onClosed`
            // (TASK-247); the manager answers it with the owner's events. Only
            // the background context may wait: a page's park would supersede
            // the worker's and take its events (pages do not get them; see the
            // polyfill-layer wiki).
            guard notificationsPermitted(extensionID, orRefuse: replyHandler) else { return }
            let registered = ExtensionManager.shared.extension(withID: extensionID)
            guard Self.senderIsBackgroundContext(sender, background: registered?.manifest.background) else {
                replyHandler(nil, "notifications events: only the background context receives them")
                return
            }
            guard let owner = notificationOwner(extensionID, orRefuse: replyHandler) else { return }
            notificationManager.awaitEvent(owner: owner, instance: params["instance"] as? String,
                                           ack: (params["ack"] as? NSNumber)?.intValue, reply: replyHandler)

        // MARK: - History
        case "history.search":
            if let refusal = permissionRefusal("history", extensionID: extensionID) {
                replyHandler(nil, refusal)
                return
            }
            let query: HistorySearchQuery
            switch Self.historySearchQuery(from: params, now: now()) {
            case .success(let parsed):
                query = parsed
            case .failure(let error):
                replyHandler(nil, error.message)
                return
            }
            // History belongs to a profile (TASK-138): the answer is built
            // from the visits of the spaces that use *this handler's* profile
            // and from nothing else — the same scope, by the same rule, as that
            // profile's History page. No scope means no history, never
            // everyone's: the Private profile records none, and a profile that
            // is deleted or released has none to show. The profile's Quick
            // Detour visits are in its scope (TASK-193.1).
            guard let spaceIDs = HistoryPageBridge.scope(forProfile: profile), !spaceIDs.isEmpty else {
                replyHandler(["results": [[String: Any]]()], nil)
                return
            }
            // Off the main thread, like the History page's query. It still
            // holds history's one serial queue while it runs, so a palette
            // read on the main thread waits for it: the default range above
            // and `searchURLs`' listing path are what keep that wait short
            // (TASK-153).
            // The read runs on a global queue; the reply, a dictionary of
            // non-Sendable values, is built back on the main actor.
            let database = historyDatabase
            Task {
                let entries = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: database.searchURLs(
                            query: query.text, spaceIDs: spaceIDs,
                            from: query.startTime, until: query.endTime, limit: query.maxResults))
                    }
                }
                replyHandler(["results": entries.map(Self.historyItem)], nil)
            }

        // MARK: - Permissions WebKit does not know (TASK-260)
        // The polyfill's `chrome.permissions` wrapper sends the `history` and
        // `management` part of a call here and the rest to WebKit, which
        // refuses these names in the web process.
        case "permissions.contains":
            switch Self.outsideWebKitPermissionNames(from: params) {
            case .failure(let error):
                replyHandler(nil, error.message)
            case .success(let names):
                // Chrome answers false for a name the manifest does not list.
                guard let ext = ExtensionManager.shared.extension(withID: extensionID) else {
                    replyHandler(false, nil)
                    return
                }
                let context = profile?.extensionContext(for: extensionID)
                let now = self.now()
                replyHandler(names.allSatisfy {
                    Self.permissionIsActive($0, manifest: ext.manifest, context: context, now: now)
                }, nil)
            }

        case "permissions.request":
            let names: [String]
            switch Self.outsideWebKitPermissionNames(from: params) {
            case .failure(let error):
                replyHandler(nil, error.message)
                return
            case .success(let parsed):
                names = parsed
            }
            guard let ext = ExtensionManager.shared.extension(withID: extensionID) else {
                replyHandler(nil, "Failed to find extension with id \(extensionID).")
                return
            }
            switch Self.permissionRequestPlan(names, manifest: ext.manifest,
                                              context: profile?.extensionContext(for: extensionID), now: now()) {
            case .refuse(let message):
                replyHandler(nil, message)
            case .answer(let granted):
                replyHandler(["granted": granted], nil)
            case .prompt(let undecided):
                ExtensionManager.shared.requestOutsideWebKitPermissions(
                    extensionID: extensionID, names: undecided) { outcome in
                    switch outcome {
                    case .approved:
                        replyHandler(["granted": true], nil)
                    case .denied:
                        replyHandler(["granted": false], nil)
                    case .refused(let message):
                        replyHandler(nil, message)
                    }
                }
            }

        case "permissions.remove":
            let names: [String]
            switch Self.outsideWebKitPermissionNames(from: params) {
            case .failure(let error):
                replyHandler(nil, error.message)
                return
            case .success(let parsed):
                names = parsed
            }
            guard let ext = ExtensionManager.shared.extension(withID: extensionID) else {
                replyHandler(nil, "Failed to find extension with id \(extensionID).")
                return
            }
            if let refusal = Self.permissionRemovalRefusal(names, manifest: ext.manifest) {
                replyHandler(nil, refusal)
                return
            }
            // The wrapper checks first, before WebKit removes the rest of a
            // mixed call, and removes only once WebKit has.
            if params["checkOnly"] as? Bool != true {
                ExtensionManager.shared.removeOutsideWebKitPermissions(extensionID: extensionID, names: names)
            }
            replyHandler(true, nil)

        // MARK: - Font Settings
        case "fontSettings.getFontList":
            // Return only system-bundled fonts to reduce fingerprinting surface.
            // The full list from NSFontManager includes user-installed fonts which
            // are unique per machine and a well-known fingerprinting vector.
            let families = NSFontManager.shared.availableFontFamilies
            let systemFonts = Self.systemFontFamilies
            let filtered = families.filter { systemFonts.contains($0) }
            let fonts: [[String: String]] = filtered.map { family in
                ["fontId": family, "displayName": family]
            }
            replyHandler(fonts, nil)

        // MARK: - Management
        case "management.getSelf":
            replyHandler(buildExtensionInfo(extensionID: extensionID), nil)

        case "management.getPermissionWarningsByManifest":
            // Permission-free in Chrome, like getSelf and uninstallSelf (TASK-257).
            switch Self.permissionWarnings(from: params) {
            case .success(let warnings): replyHandler(warnings, nil)
            case .failure(let error): replyHandler(nil, error.message)
            }

        case "management.uninstallSelf":
            // Permission-free in Chrome. The verified id is the only one this
            // can act on: an extension uninstalls itself, never another.
            switch Self.uninstallSelfShowsConfirmDialog(from: params) {
            case .failure(let error):
                replyHandler(nil, error.message)
            case .success(let showConfirmDialog):
                ExtensionManager.shared.uninstallSelf(extensionID: extensionID,
                                                      showConfirmDialog: showConfirmDialog) { error in
                    replyHandler(error == nil ? true : nil, error)
                }
            }

        case "management.getAll":
            if let refusal = permissionRefusal("management", extensionID: extensionID) {
                replyHandler(nil, refusal)
                return
            }
            let allInfos = ExtensionManager.shared.extensions.map { ext in
                buildExtensionInfo(ext: ext)
            }
            replyHandler(allInfos, nil)

        case "management.setEnabled":
            // Deliberately a no-op that reports success: Detour never enables or
            // disables one extension on another extension's say-so — that is the
            // user's decision, made in Settings. 1Password calls this only to
            // disable its sibling channel builds (stable/beta/nightly) when more
            // than one is installed; rejecting would surface as a setup failure,
            // so the call is logged and ignored. Extension ids are public.
            //
            // Chrome gates setEnabled on the `management` permission (only
            // getSelf/uninstallSelf are permission-free), so an extension that
            // never declared it gets the same rejection it would get in Chrome
            // rather than a silent success.
            if let refusal = permissionRefusal("management", extensionID: extensionID) {
                replyHandler(nil, refusal)
                return
            }
            let targetID = params["id"] as? String ?? "(none)"
            let enabled = params["enabled"] as? Bool ?? true
            log.info("management.setEnabled ignored: \(extensionID, privacy: .public) asked to set \(targetID, privacy: .public) enabled=\(enabled, privacy: .public)")
            replyHandler(true, nil)

        // MARK: - Sessions
        case "sessions.restore":
            guard let space = targetSpace() else {
                replyHandler(nil, "No space in this profile")
                return
            }
            guard let tab = TabStore.shared.reopenClosedTab(in: space) else {
                replyHandler(nil, "No closed tabs to restore")
                return
            }
            NotificationCenter.default.post(
                name: ExtensionManager.tabShouldSelectNotification,
                object: nil,
                userInfo: ["tabID": tab.id, "spaceID": space.id]
            )
            replyHandler(["tab": ["id": tab.id.hashValue, "url": tab.url?.absoluteString ?? ""]], nil)

        // MARK: - Search
        case "search.query":
            let query = params["query"] as? [String: Any] ?? params
            let text = query["text"] as? String ?? ""

            guard let space = targetSpace() else {
                replyHandler(nil, "No space in this profile")
                return
            }
            let engine = profile?.searchEngine ?? .google
            guard let searchURL = engine.searchURL(for: text) else {
                replyHandler(nil, "Failed to build search URL")
                return
            }
            let tab = TabStore.shared.addTab(in: space, url: searchURL)
            space.selectedTabID = tab.id
            NotificationCenter.default.post(
                name: ExtensionManager.tabShouldSelectNotification,
                object: nil,
                userInfo: ["tabID": tab.id, "spaceID": space.id]
            )
            replyHandler(["success": true], nil)

        // MARK: - Offscreen
        case "offscreen.createDocument":
            let url = params["url"] as? String ?? "offscreen.html"
            log.info("offscreen.createDocument: url=\(url, privacy: .private) ext=\(extensionID, privacy: .public)")
            // Only this profile's context will do: the document is hosted per
            // handler (i.e. per profile), so it must get this profile's data
            // store and be torn down by this profile's `unloadExtension`.
            // A global lookup would hand back the last-active space's profile,
            // which can be a different one.
            let resolvedContext = profile?.extensionContext(for: extensionID)
            guard let ext = ExtensionManager.shared.extension(withID: extensionID),
                  let context = resolvedContext else {
                log.error("offscreen.createDocument: extension not found, or its context is not loaded in this profile, for \(extensionID, privacy: .public)")
                replyHandler(nil, "Extension not found")
                return
            }
            if let existing = offscreenHosts[extensionID] {
                if existing.isLoading {
                    // A document is being created but is not there yet. Wait on
                    // that load rather than reporting success now: it may still
                    // fail, and this request must then fail with it instead of
                    // holding a resolved promise for a document that never came.
                    log.info("offscreen.createDocument: joining the load in flight for \(extensionID, privacy: .public)")
                    existing.addLoadCompletion(
                        offscreenLoadCompletion(extensionID: extensionID, host: existing, replyHandler: replyHandler))
                } else {
                    log.info("offscreen.createDocument: already exists for \(extensionID, privacy: .public), returning success")
                    replyHandler(true, nil)
                }
                return
            }

            let host = OffscreenDocumentHost(extensionID: extensionID, basePath: ext.basePath)
            offscreenHosts[extensionID] = host
            let config = context.webViewConfiguration
            log.info("offscreen.createDocument: baseURL=\(context.baseURL.absoluteString, privacy: .public)")
            host.load(url: url, configuration: config, baseURL: context.baseURL,
                      completion: offscreenLoadCompletion(extensionID: extensionID, host: host, replyHandler: replyHandler))

        case "offscreen.closeDocument":
            closeOffscreenDocument(for: extensionID)
            replyHandler(true, nil)

        case "offscreen.hasDocument":
            // A host whose load has not settled is not a document yet.
            let hasDoc = offscreenHosts[extensionID].map { !$0.isLoading } ?? false
            replyHandler(hasDoc, nil)

        // MARK: - i18n
        case "i18n.detectLanguage":
            let text = params["text"] as? String ?? ""
            guard !text.isEmpty else {
                replyHandler(["isReliable": false, "languages": [["language": "und", "percentage": 100]]], nil)
                return
            }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            var languages: [[String: Any]] = []
            // Get top hypotheses with confidence scores
            let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
            for (lang, confidence) in hypotheses.sorted(by: { $0.value > $1.value }) {
                languages.append([
                    "language": lang.rawValue,
                    "percentage": Int(confidence * 100)
                ])
            }
            if languages.isEmpty {
                languages.append(["language": "und", "percentage": 100])
            }
            let isReliable = (hypotheses.first?.value ?? 0) > 0.7
            replyHandler(["isReliable": isReliable, "languages": languages], nil)

        // MARK: - runtime.lastError relay
        case Self.lastErrorRelayType:
            // Always fails, with the caller's own message as the error. The
            // polyfill sends this through the native, callback-style
            // `runtime.sendNativeMessage` when a polyfilled API rejects and
            // WebKit's `runtime.lastError` cannot be set from JS: WebKit then
            // runs the extension's callback with lastError carrying the
            // message (TASK-23; `__detourSettle` in ExtensionAPIPolyfill). It
            // echoes the sender's text back to the sender only, so it needs no
            // permission. Capped so a runaway string is not carried through IPC.
            let message = (params["message"] as? String).map { String($0.prefix(Self.lastErrorRelayMessageLimit)) } ?? ""
            replyHandler(nil, message.isEmpty ? "Unknown error" : message)

        // MARK: - runtime.onUpdateAvailable (TASK-123)
        case "runtime.awaitUpdateAvailable":
            // The background polyfill parks this request; it is answered when an
            // update is staged for the extension (or at once if one already is).
            // Only the background context may wait: the event is its.
            let registered = ExtensionManager.shared.extension(withID: extensionID)
            guard Self.senderIsBackgroundContext(sender, background: registered?.manifest.background), let profile else {
                replyHandler(nil, "runtime.onUpdateAvailable: only the background context receives the event")
                return
            }
            ExtensionManager.shared.awaitUpdateAvailable(extensionID: extensionID, profileID: profile.id,
                                                         instance: params["instance"] as? String, reply: replyHandler)

        // MARK: - runtime.requestUpdateCheck
        case "runtime.requestUpdateCheck":
            // A real check (TASK-113), throttled per extension by the updater.
            // Any context of the extension may ask, as in Chrome.
            Task { @MainActor in
                let outcome = await ExtensionUpdater.shared.requestUpdateCheck(extensionID: extensionID)
                replyHandler(Self.requestUpdateCheckReply(for: outcome), nil)
            }

        // MARK: - runtime.onInstalled
        case "runtime.claimInstalledEvent":
            // The background polyfill asks once per background-context start
            // (TASK-22, TASK-43). Only the background context may ask: the
            // claim advances the ledger, so a popup, options page, extension
            // tab or an iframe of the background path calling
            // `__detourPolyfillRequest` directly would otherwise consume its
            // own extension's install and the real background context would
            // never get it (TASK-64). Verified identity is not enough — every
            // one of those contexts has it — so the *sender* is checked
            // against the manifest's background shape, and the refusal returns
            // before the ledger call so the event stays pending.
            let registered = ExtensionManager.shared.extension(withID: extensionID)
            guard Self.senderIsBackgroundContext(sender, background: registered?.manifest.background) else {
                log.warning("runtime.claimInstalledEvent: refusing a claim from \(extensionID, privacy: .public) (\(sender.logDescription, privacy: .public)); only the background context may claim")
                replyHandler(nil, "runtime.claimInstalledEvent: only the background context may claim the event")
                return
            }
            // The version is the one this profile's context actually runs; the
            // manifest is the fallback for a context this profile does not hold.
            guard let profile,
                  let version = profile.extensionContext(for: extensionID)?.webExtension.version
                    ?? registered?.manifest.version else {
                replyHandler([:] as [String: Any], nil)
                return
            }
            // Every background start passes here once (TASK-43); a start that
            // follows an `onUpdateAvailable` delivery to an earlier incarnation
            // of the context is the extension's `runtime.reload()`, which
            // installs the staged update (TASK-123). The incarnation token tells
            // that delivery from one this start's own listener asked for.
            // Deferred to the next turn so this start's reply goes out first.
            let startedProfileID = profile.id
            let startedInstance = params["instance"] as? String
            Task { @MainActor in
                ExtensionManager.shared.backgroundContextDidStart(extensionID: extensionID, profileID: startedProfileID,
                                                                  instance: startedInstance)
            }
            // The claim's timer was queued before the extension's own script
            // ran, so a worker whose script threw claims too. An event is
            // recorded as delivered only when a listener was there to get it,
            // or there was none and the load did not fail (TASK-134).
            let claimingContext = profile.extensionContext(for: extensionID)
            let listenerCount = (params["listeners"] as? NSNumber)?.intValue
            let disposition = RuntimeInstalledEvent.claimDisposition(
                listenerCount: listenerCount,
                backgroundLoadFailed: claimingContext?.hasBackgroundContentLoadFailure ?? false)
            guard disposition != .withhold else {
                log.notice("runtime.onInstalled: not delivering to \(extensionID, privacy: .public) in profile \(profile.name, privacy: .public): its background content failed to load before it registered a listener; the event stays owed")
                replyHandler([:] as [String: Any], nil)
                return
            }
            // The Private profile never gets the event (TASK-29): the claim
            // answers nothing there and writes no ledger row.
            guard let claim = AppDatabase.shared.claimRuntimeInstalledEventKeepingPrevious(
                extensionID: extensionID, profileID: profile.id.uuidString,
                isPrivateProfile: profile.isIncognito, currentVersion: version
            ) else {
                replyHandler([:] as [String: Any], nil)
                return
            }
            if disposition == .deliverProvisionally, let claimingContext {
                ProvisionalInstalledEventClaims.shared.record(claim, context: claimingContext, extensionID: extensionID,
                                                              profileID: profile.id.uuidString)
            }
            let details = claim.details
            log.notice("runtime.onInstalled: delivering \(details.reason.rawValue, privacy: .public) (previous \(details.previousVersion ?? "none", privacy: .public), now \(version, privacy: .public)) to \(extensionID, privacy: .public) in profile \(profile.name, privacy: .public), \(listenerCount.map { "\($0) listener(s)" } ?? "listeners not reported", privacy: .public)")
            replyHandler(details.dictionary, nil)

        // MARK: - Logging Bridge
        case "log":
            // Extension console output is arbitrary extension data (1Password
            // logs native-messaging responses). By default it is `.private`,
            // which keeps it out of the persisted log while Xcode still shows
            // it with a debugger attached. For debugging sessions on a build
            // that can't run under Xcode (1Password only trusts the signed
            // /Applications build), the message can be logged publicly by
            // opting in per session; see `consoleLogIsPublic`.
            let level = params["level"] as? String ?? "info"
            let message = params["message"] as? String ?? ""
            let source = params["source"] as? String ?? extensionID
            // Cap the log writes per extension per second regardless of what the
            // context's own limiter did (TASK-17). The reply is still `true`: the
            // bridge is fire-and-forget and a rejection would only make the
            // polyfill's own error reporting noisier.
            switch consoleLimiter.admit(extensionID) {
            case .drop:
                replyHandler(true, nil)
                return
            case .dropReportingFlood(let droppedSoFar, let since):
                // An extension that has been over the cap without a pause for a
                // full minute (TASK-90: 1Password's worker logged 20 errors a
                // second for hours). Reported once per incident, at error level
                // and naming the profile, because the point is that the next
                // incident is diagnosable from `log show` alone — the flood
                // itself evicts everything else from the log store.
                //
                // Logging is the whole reaction, by decision. Restarting the
                // worker was the obvious alternative and is the wrong one: in
                // the incident this was written for, a restarted worker
                // re-entered the same loop within a minute (the root cause was
                // its IndexedDB being purged under it), so a restart would have
                // bought nothing and an automatic one invites a restart loop on
                // top of the message loop. A user-visible notice was rejected
                // for the same reason — there is nothing the user could do about
                // an extension's own error loop.
                log.error("[console bridge] flood from \(extensionID, privacy: .public) in profile \(self.profile?.name ?? "(released)", privacy: .public): \(droppedSoFar, privacy: .public) messages dropped over \(String(format: "%.0f", since), privacy: .public)s of unbroken over-cap logging; the bridge stays capped at \(Int(ConsoleBridgeLimiter.sustainedRatePerSecond), privacy: .public) messages/s for this extension. Logging only — no worker restart, no user notice.")
                replyHandler(true, nil)
                return
            case .allowReportingDropped(let count, let interval):
                // Same prefix as the polyfill's own summary so one log predicate
                // finds both halves of an incident. `interval` is the span the
                // reported drops accumulated over, so unlike the old fixed
                // window's it is a fair denominator.
                log.warning("[console bridge] dropped \(count, privacy: .public) messages from \(extensionID, privacy: .public) over the \(ConsoleBridgeLimiter.burstCapacity, privacy: .public)-message burst / \(Int(ConsoleBridgeLimiter.sustainedRatePerSecond), privacy: .public)-per-second cap, in \(String(format: "%.1f", interval), privacy: .public)s")
            case .allow:
                break
            }
            if Self.consoleLogIsPublic {
                switch level {
                case "error": log.error("[SW \(source, privacy: .public)] \(message, privacy: .public)")
                case "warn":  log.warning("[SW \(source, privacy: .public)] \(message, privacy: .public)")
                default:      log.info("[SW \(source, privacy: .public)] \(message, privacy: .public)")
                }
            } else {
                switch level {
                case "error": log.error("[SW \(source, privacy: .public)] \(message, privacy: .private)")
                case "warn":  log.warning("[SW \(source, privacy: .public)] \(message, privacy: .private)")
                default:      log.info("[SW \(source, privacy: .public)] \(message, privacy: .private)")
                }
            }
            replyHandler(true, nil)

        default:
            log.warning("Unknown polyfill message type: \(type, privacy: .public)")
            replyHandler(nil, "Unknown polyfill message type: \(type)")
        }
    }

    // MARK: - Helpers

    /// The space an action that creates or restores a tab must act in. The
    /// handler is profile-scoped, so such a tab belongs in one of *this*
    /// profile's spaces — it gets that profile's cookies and search engine, and
    /// its closed-tab stack is the only one this profile's extensions may
    /// reopen from. Which one is `tabs.create`'s rule,
    /// `ExtensionManager.newTabSpace(for:)`: the space the profile used last
    /// (TASK-226). Nil when the profile is gone, or has no space at all —
    /// never another profile's space.
    private func targetSpace() -> Space? {
        guard let profile else { return nil }
        return ExtensionManager.shared.newTabSpace(for: profile)
    }

    /// Why the extension may not use `permission` now, in this handler's
    /// profile, or nil when it may. Gates the polyfilled APIs (history,
    /// management, notifications) that WKWebExtension doesn't itself
    /// permission-check because they're implemented natively here. See
    /// `permissionRefusal(_:manifest:context:now:)`.
    private func permissionRefusal(_ permission: String, extensionID: String) -> String? {
        guard let ext = ExtensionManager.shared.extension(withID: extensionID) else {
            return Self.permissionNotDeclared(permission)
        }
        return Self.permissionRefusal(permission, manifest: ext.manifest,
                                      context: profile?.extensionContext(for: extensionID), now: now())
    }

    /// The refusal of a call whose permission is not active
    /// (`permissionIsActive`), saying which of three states it is in
    /// (TASK-260), or nil when it is active:
    /// - not in either manifest list: "<name> permission not declared";
    /// - denied in this context, by the Settings switch, a prompt answered
    ///   Deny, or that saved denial restored: "<name> permission denied by
    ///   the user";
    /// - listed only under `optional_permissions` and not granted:
    ///   "<name> permission is optional and has not been granted", which
    ///   `permissions.request` can change.
    static func permissionRefusal(_ permission: String, manifest: ExtensionManifest,
                                  context: WKWebExtensionContext?, now: Date = Date()) -> String? {
        if permissionIsActive(permission, manifest: manifest, context: context, now: now) { return nil }
        let required = manifest.permissions?.contains(permission) == true
        let optional = manifest.optionalPermissions?.contains(permission) == true
        guard required || optional else { return permissionNotDeclared(permission) }
        let key = WKWebExtension.Permission(rawValue: permission)
        if let deniedUntil = context?.deniedPermissions[key], deniedUntil > now {
            return "\(permission) permission denied by the user"
        }
        return "\(permission) permission is optional and has not been granted"
    }

    static func permissionNotDeclared(_ permission: String) -> String {
        "\(permission) permission not declared"
    }

    /// The rule behind `permissionRefusal`, WebKit's own order for the APIs it
    /// implements (`WebExtensionContext::permissionState`): a denial in
    /// `context` refuses first, then a grant serves.
    ///
    /// `context` is one profile's, but what it holds is not a per-profile
    /// decision: a saved grant or denial belongs to the extension, and Detour
    /// applies it to the extension's context in every profile, the Private
    /// one included (`ExtensionManager.setPermissionDecision`, the restore in
    /// `Profile.loadExtensionContext`). The one gap: an answer to WebKit's own
    /// `permissions.request` prompt is saved for the extension
    /// (`ExtensionManager.handlePermissionPrompt`), but WebKit applies it to
    /// the asking context alone, so the other profiles' contexts get it at
    /// their next load.
    ///
    /// - A permission the manifest requires is active unless `context` holds
    ///   an unexpired denial of it: the Settings switch turned off
    ///   (`ExtensionManager.setPermissionDecision`), or that saved denial
    ///   restored at load (`Profile.loadExtensionContext`). Switched on again,
    ///   it is active at once (TASK-259). With no decision at all it stays
    ///   active: install saves the required permissions as granted, and
    ///   WebKit never prompts for `history` or `management`, so an undecided
    ///   required one has no way to become granted. No context, no denial to
    ///   read: active, as before.
    /// - One listed only under `optional_permissions` is active while
    ///   `context` holds an unexpired grant for it, and Chrome makes it
    ///   available as soon as it is granted and takes it away on revocation
    ///   (TASK-250). The grant gets there from a `permissions.request`
    ///   prompt (WebKit's, or Detour's for the names WebKit does not know),
    ///   from the Settings switch and from the
    ///   restore of a saved decision at load. A switch turned off takes it out
    ///   again, and so does `permissions.remove`. WebKit refuses
    ///   `permissions.request`, `contains` and `remove` for `history` and
    ///   `management` in the web process ("is not a valid permission"), so the
    ///   polyfill takes those two names out of the call and the
    ///   `permissions.*` requests here answer for them (TASK-260). No context
    ///   means no grant.
    ///
    /// The grant and denial dictionaries are read rather than
    /// `WKWebExtensionContext.hasPermission(_:)`, because WebKit answers `.unknown` for every name
    /// outside its own permission set (`history`, `management`) while still
    /// storing the status it is given.
    static func permissionIsActive(_ permission: String, manifest: ExtensionManifest,
                                   context: WKWebExtensionContext?, now: Date = Date()) -> Bool {
        let key = WKWebExtension.Permission(rawValue: permission)
        if let deniedUntil = context?.deniedPermissions[key], deniedUntil > now { return false }
        if manifest.permissions?.contains(permission) == true { return true }
        guard manifest.optionalPermissions?.contains(permission) == true,
              let expiry = context?.grantedPermissions[key]
        else { return false }
        return expiry > now
    }

    private func buildExtensionInfo(extensionID: String) -> [String: Any] {
        if let ext = ExtensionManager.shared.extension(withID: extensionID) {
            return buildExtensionInfo(ext: ext)
        }
        return ["id": extensionID, "type": "extension"]
    }

    private func buildExtensionInfo(ext: WebExtension) -> [String: Any] {
        var info: [String: Any] = [
            "id": ext.id,
            "name": ExtensionManager.shared.displayName(for: ext.id),
            "version": ext.manifest.version ?? "0.0.0",
            "enabled": ext.isEnabled,
            "type": "extension",
            "installType": "development",
            "mayDisable": true,
        ]
        if let desc = ExtensionManager.shared.displayDescription(for: ext.id) {
            info["description"] = desc
        }
        let context = profile?.extensionContext(for: ext.id)
        let now = self.now()
        info["permissions"] = Self.activeAPIPermissions(manifest: ext.manifest, context: context, now: now)
        info["hostPermissions"] = context.map {
            Self.activeHostPermissions(granted: $0.grantedPermissionMatchPatterns,
                                       denied: $0.deniedPermissionMatchPatterns,
                                       askable: ext.askableMatchPatterns,
                                       implicit: Self.implicitContentScriptPatterns(ext.manifest),
                                       now: now)
        } ?? Self.declaredRequiredHosts(ext.manifest)
        return info
    }

    /// `ExtensionInfo.permissions` (TASK-261): the API permissions active in
    /// `context`, as Chromium's `CreateExtensionInfo` lists
    /// `active_permissions().GetAPIsAsStrings()` — required ones not switched
    /// off, optional ones while granted. Manifest order, required first.
    static func activeAPIPermissions(manifest: ExtensionManifest, context: WKWebExtensionContext?,
                                     now: Date = Date()) -> [String] {
        var seen = Set<String>()
        return ((manifest.permissions ?? []) + (manifest.optionalPermissions ?? [])).filter {
            !isHostPermissionString($0) && seen.insert($0).inserted
                && permissionIsActive($0, manifest: manifest, context: context, now: now)
        }
    }

    /// With no context in the asking profile there is no grant or denial to
    /// read, so, as `permissionIsActive` treats required API permissions, the
    /// required hosts: `host_permissions`, or MV2's origins in `permissions`.
    private static func declaredRequiredHosts(_ manifest: ExtensionManifest) -> [String] {
        (manifest.hostPermissions ?? []) + (manifest.permissions ?? []).filter(isHostPermissionString)
    }

    /// A Manifest V2 `permissions` / `optional_permissions` entry that is an
    /// origin rather than an API name. Chromium lists those under
    /// `hostPermissions`, never `permissions`.
    private static func isHostPermissionString(_ entry: String) -> Bool {
        entry == "<all_urls>" || entry.contains("://")
    }

    /// The content-script match patterns `Profile.loadExtensionContext` grants
    /// for `activeTab` that the manifest does not also list as a host
    /// permission. A manifest host pattern can cover them (`<all_urls>` over a
    /// `https://*/*` content script), so the `askable` filter alone keeps them.
    static func implicitContentScriptPatterns(_ manifest: ExtensionManifest) -> Set<String> {
        guard manifest.permissions?.contains("activeTab") == true else { return [] }
        let declared = Set((manifest.hostPermissions ?? []) + (manifest.optionalHostPermissions ?? [])
            + ((manifest.permissions ?? []) + (manifest.optionalPermissions ?? [])).filter(isHostPermissionString))
        return Set((manifest.contentScripts ?? []).flatMap(\.matches)).subtracting(declared)
    }

    /// `ExtensionInfo.hostPermissions` (TASK-261): Chromium lists
    /// `active_permissions().explicit_hosts()`, the granted `host_permissions`
    /// and `optional_host_permissions` origins, not the content-script hosts.
    /// So: the unexpired granted patterns some manifest host pattern covers
    /// (`askable` — this leaves out the content-script patterns
    /// `Profile.loadExtensionContext` grants for `activeTab`), minus those
    /// an unexpired denial covers (WebKit keeps a narrower grant under a
    /// denied `<all_urls>`) and those in `implicit` (the `activeTab`
    /// content-script grants a manifest host pattern covers). Sorted, each
    /// string once.
    static func activeHostPermissions(granted: [WKWebExtension.MatchPattern: Date],
                                      denied: [WKWebExtension.MatchPattern: Date],
                                      askable: Set<WKWebExtension.MatchPattern>,
                                      implicit: Set<String> = [],
                                      now: Date = Date()) -> [String] {
        let liveDenials = denied.filter { $0.value > now }.keys
        let active = granted.filter { pattern, expiry in
            expiry > now && !implicit.contains(pattern.string)
                && !liveDenials.contains { $0.string == pattern.string || $0.matches(pattern) }
                && askable.contains { $0.matches(pattern) }
        }
        return Set(active.keys.map(\.string)).sorted()
    }

    /// Font families bundled with macOS. Used to filter getFontList results
    /// so user-installed fonts (a fingerprinting vector) are not exposed.
    private static let systemFontFamilies: Set<String> = [
        // System UI
        ".AppleSystemUIFont", "System Font", "SF Pro", "SF Pro Display", "SF Pro Text",
        "SF Pro Rounded", "SF Compact", "SF Compact Display", "SF Compact Text",
        "SF Compact Rounded", "SF Mono", "New York",
        // Serif
        "Times New Roman", "Times", "Georgia", "Palatino", "Baskerville",
        "Big Caslon", "Cochin", "Didot", "Garamond", "Hoefler Text",
        "Iowan Old Style", "Superclarendon",
        // Sans-serif
        "Arial", "Arial Black", "Avenir", "Avenir Next", "Avenir Next Condensed",
        "Futura", "Geneva", "Gill Sans", "Helvetica", "Helvetica Neue",
        "Lucida Grande", "Optima", "Trebuchet MS", "Verdana",
        // Monospace
        "Courier", "Courier New", "Menlo", "Monaco", "Andale Mono",
        // Decorative / Display
        "American Typewriter", "Brush Script MT", "Chalkboard", "Chalkboard SE",
        "Chalkduster", "Comic Sans MS", "Copperplate", "Impact",
        "Marker Felt", "Noteworthy", "Papyrus", "Party LET",
        "Phosphate", "Rockwell", "Savoye LET", "SignPainter",
        "Snell Roundhand", "Zapfino",
        // CJK
        "Hiragino Sans", "Hiragino Mincho ProN", "PingFang SC", "PingFang TC",
        "PingFang HK", "Songti SC", "Songti TC", "STSong",
        "Apple SD Gothic Neo", "Nanum Gothic",
        // Other scripts
        "Al Nile", "Al Tarikh", "Baghdad", "Damascus", "Farah",
        "Geeza Pro", "Kohinoor Bangla", "Kohinoor Devanagari", "Kohinoor Telugu",
        "Mishafi", "Muna", "Sana",
        "Kefa", "Khmer Sangam MN", "Lao Sangam MN", "Malayalam Sangam MN",
        "Oriya Sangam MN", "Sinhala Sangam MN", "Tamil Sangam MN",
        // Symbol
        "Apple Symbols", "Symbol", "Webdings", "Wingdings", "Wingdings 2", "Wingdings 3",
        "Zapf Dingbats",
    ]
}
