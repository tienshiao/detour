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

    /// Longest relayed lastError message, in characters.
    static let lastErrorRelayMessageLimit = 2048

    /// The profile whose extension controller this handler serves.
    private(set) weak var profile: Profile?

    init(profile: Profile) {
        self.profile = profile
        super.init()
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

    // MARK: - Entry Points

    /// Entry point for web view contexts (popup, options) via WKScriptMessageHandlerWithReply.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
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
                replyHandler(nil, NSError(domain: "DetourPolyfill", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: errorString]))
            } else {
                log.debug("Polyfill success for \(type, privacy: .public)")
                replyHandler(result, nil)
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
        case "notifications.create":
            let notificationId = params["notificationId"] as? String
            let options = params["options"] as? [String: Any] ?? [:]
            ExtensionNotificationManager.shared.create(
                extensionID: extensionID, notificationID: notificationId, options: options
            ) { id in
                replyHandler(["notificationId": id], nil)
            }

        case "notifications.update":
            guard let notificationId = params["notificationId"] as? String else {
                replyHandler(nil, "notificationId required")
                return
            }
            let options = params["options"] as? [String: Any] ?? [:]
            ExtensionNotificationManager.shared.update(
                extensionID: extensionID, notificationID: notificationId, options: options
            ) { updated in
                replyHandler(["wasUpdated": updated], nil)
            }

        case "notifications.clear":
            guard let notificationId = params["notificationId"] as? String else {
                replyHandler(nil, "notificationId required")
                return
            }
            ExtensionNotificationManager.shared.clear(
                extensionID: extensionID, notificationID: notificationId
            ) { cleared in
                replyHandler(["wasCleared": cleared], nil)
            }

        case "notifications.getAll":
            let all = ExtensionNotificationManager.shared.getAll(extensionID: extensionID)
            replyHandler(all, nil)

        // MARK: - History
        case "history.search":
            guard hasPermission("history", extensionID: extensionID) else {
                replyHandler(nil, "history permission not declared")
                return
            }
            let query = params["query"] as? [String: Any] ?? [:]
            let text = query["text"] as? String ?? ""
            let maxResults = query["maxResults"] as? Int ?? 100
            let startTime = (query["startTime"] as? Double).map { $0 / 1000.0 }
            let endTime = (query["endTime"] as? Double).map { $0 / 1000.0 }

            let results = HistoryDatabase.shared.searchHistoryGlobal(
                query: text, maxResults: maxResults, startTime: startTime, endTime: endTime
            )

            let items: [[String: Any]] = results.map { item in
                [
                    "id": String(item.id ?? 0),
                    "url": item.url,
                    // A URL can be left with no title at all (TASK-91: the visit
                    // its latest known title came from was deleted). Chrome's
                    // history items always carry something displayable, so fall
                    // back to the URL rather than handing back an empty string.
                    "title": item.title.isEmpty ? item.url : item.title,
                    "lastVisitTime": item.lastVisitTime * 1000.0,
                    "visitCount": item.visitCount,
                    "typedCount": 0
                ]
            }
            replyHandler(["results": items], nil)

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

        case "management.getAll":
            guard hasPermission("management", extensionID: extensionID) else {
                replyHandler(nil, "management permission not declared")
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
            guard hasPermission("management", extensionID: extensionID) else {
                replyHandler(nil, "management permission not declared")
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

        // MARK: - Favicon
        case "favicon.lookup":
            let pageUrl = params["pageUrl"] as? String ?? ""
            if let faviconURL = HistoryDatabase.shared.faviconURL(for: pageUrl) {
                replyHandler(["faviconURL": faviconURL], nil)
            } else {
                replyHandler([:] as [String: Any], nil)
            }

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
            // The Private profile never gets the event (TASK-29): the claim
            // answers nothing there and writes no ledger row.
            guard let details = AppDatabase.shared.claimRuntimeInstalledEvent(
                extensionID: extensionID, profileID: profile.id.uuidString,
                isPrivateProfile: profile.isIncognito, currentVersion: version
            ) else {
                replyHandler([:] as [String: Any], nil)
                return
            }
            log.notice("runtime.onInstalled: delivering \(details.reason.rawValue, privacy: .public) (previous \(details.previousVersion ?? "none", privacy: .public), now \(version, privacy: .public)) to \(extensionID, privacy: .public) in profile \(profile.name, privacy: .public)")
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
    /// reopen from. The last-active space is preferred only when it is one of
    /// them (it is global, and the focused window can belong to another
    /// profile); otherwise the profile's first space. Nil when the profile is
    /// gone, or has no space at all — never another profile's space.
    private func targetSpace() -> Space? {
        guard let profile else { return nil }
        if let lastActiveID = ExtensionManager.shared.lastActiveSpaceID,
           let lastActive = TabStore.shared.space(withID: lastActiveID),
           lastActive.profileID == profile.id {
            return lastActive
        }
        return TabStore.shared.spaces.first { $0.profileID == profile.id }
    }

    /// Whether the extension declared a given manifest permission. Used to gate
    /// polyfilled APIs (history, management) that WKWebExtension doesn't itself
    /// permission-check because they're implemented natively here.
    private func hasPermission(_ permission: String, extensionID: String) -> Bool {
        ExtensionManager.shared.extension(withID: extensionID)?.manifest.permissions?.contains(permission) ?? false
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
        if let permissions = ext.manifest.permissions {
            info["permissions"] = permissions
        }
        return info
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
