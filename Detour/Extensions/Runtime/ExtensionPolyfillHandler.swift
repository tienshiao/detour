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
    /// `createDocument` still loading is settled by `stop()` running its
    /// completion, which sees the host gone and fails the request.
    func closeOffscreenDocument(for extensionID: String) {
        guard let host = offscreenHosts.removeValue(forKey: extensionID) else { return }
        host.stop()
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
        dispatch(body, verifiedExtensionID: verifiedExtensionID, replyHandler: replyHandler)
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
        dispatch(body, verifiedExtensionID: verifiedExtensionID) { result, errorString in
            if let errorString {
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
    /// establish one, so the body's `extensionID` is never trusted.
    private func dispatch(_ body: [String: Any], verifiedExtensionID extensionID: String, replyHandler: @escaping (Any?, String?) -> Void) {
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
                    "title": item.title,
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
            guard offscreenHosts[extensionID] == nil else {
                log.info("offscreen.createDocument: already exists for \(extensionID, privacy: .public), returning success")
                replyHandler(true, nil)
                return
            }

            let host = OffscreenDocumentHost(extensionID: extensionID, basePath: ext.basePath)
            offscreenHosts[extensionID] = host
            let config = context.webViewConfiguration
            log.info("offscreen.createDocument: baseURL=\(context.baseURL.absoluteString, privacy: .public)")
            host.load(url: url, configuration: config, baseURL: context.baseURL) { [weak self, weak host] in
                // `stop()` also runs this when the document is closed (explicitly
                // or by a context unload) before it finished loading; the request
                // must settle either way, and must not report a document that is gone.
                guard let self, let host, self.offscreenHosts[extensionID] === host else {
                    log.info("offscreen.createDocument: closed before it finished loading for \(extensionID, privacy: .public)")
                    replyHandler(nil, "Offscreen document was closed before it finished loading")
                    return
                }
                log.info("offscreen.createDocument: loaded successfully for \(extensionID, privacy: .public)")
                replyHandler(true, nil)
            }

        case "offscreen.closeDocument":
            closeOffscreenDocument(for: extensionID)
            replyHandler(true, nil)

        case "offscreen.hasDocument":
            let hasDoc = offscreenHosts[extensionID] != nil
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

        // MARK: - WebNavigation
        case "webNavigation.getAllFrames":
            replyHandler(Self.defaultFrameInfo, nil)

        case "webNavigation.getFrame":
            let frameId = params["frameId"] as? Int ?? 0
            if frameId == 0 {
                replyHandler(Self.defaultFrameInfo[0], nil)
            } else {
                replyHandler(["frameId": frameId, "parentFrameId": -1, "url": ""], nil)
            }

        // MARK: - Favicon
        case "favicon.lookup":
            let pageUrl = params["pageUrl"] as? String ?? ""
            if let faviconURL = HistoryDatabase.shared.faviconURL(for: pageUrl) {
                replyHandler(["faviconURL": faviconURL], nil)
            } else {
                replyHandler([:] as [String: Any], nil)
            }

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

    /// Basic top-level frame info. Cross-origin iframe enumeration isn't possible
    /// from the extension context, so we return a minimal result.
    private static let defaultFrameInfo: [[String: Any]] = [["frameId": 0, "parentFrameId": -1, "url": ""]]

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
