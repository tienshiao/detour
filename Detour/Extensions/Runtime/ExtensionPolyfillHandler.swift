import Foundation
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-polyfill")

/// Handles native-backed Chrome extension API requests from the JS polyfills.
/// Registered as a `WKScriptMessageHandlerWithReply` on the extension controller's
/// web view configuration, so all extension contexts (background, popup, content)
/// can send messages and receive async responses.
class ExtensionPolyfillHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "detourPolyfill"

    /// Active offscreen document hosts, keyed by extensionID.
    var offscreenHosts: [String: OffscreenDocumentHost] = [:]

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
        dispatch(body, replyHandler: replyHandler)
    }

    /// Entry point for service worker contexts via browser.runtime.sendNativeMessage.
    /// Called by ExtensionManager's delegate when appID == "detourPolyfill".
    func handleNativeMessage(_ body: [String: Any], replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        let type = body["type"] as? String ?? "(unknown)"
        log.info("Native message bridge: \(type, privacy: .public)")
        dispatch(body) { result, errorString in
            if let errorString {
                log.error("Polyfill error for \(type, privacy: .public): \(errorString, privacy: .public)")
                replyHandler(nil, NSError(domain: "DetourPolyfill", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: errorString]))
            } else {
                log.info("Polyfill success for \(type, privacy: .public)")
                replyHandler(result, nil)
            }
        }
    }

    // MARK: - Dispatch

    private func dispatch(_ body: [String: Any], replyHandler: @escaping (Any?, String?) -> Void) {
        guard let type = body["type"] as? String,
              let extensionID = body["extensionID"] as? String else {
            log.error("Invalid polyfill message: missing type or extensionID in \(String(describing: body), privacy: .public)")
            replyHandler(nil, "Invalid message format: missing type or extensionID")
            return
        }

        log.info("Polyfill request: \(type, privacy: .public) from \(extensionID, privacy: .public)")
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
            let allInfos = ExtensionManager.shared.extensions.map { ext in
                buildExtensionInfo(ext: ext)
            }
            replyHandler(allInfos, nil)

        // MARK: - Sessions
        case "sessions.restore":
            let mgr = ExtensionManager.shared
            guard let spaceID = mgr.lastActiveSpaceID,
                  let space = TabStore.shared.space(withID: spaceID) else {
                replyHandler(nil, "No active space")
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

            let mgr2 = ExtensionManager.shared
            let space: Space? = mgr2.lastActiveSpaceID.flatMap { TabStore.shared.space(withID: $0) }
                ?? TabStore.shared.spaces.first
            let engine = space?.profile?.searchEngine ?? .google
            guard let searchURL = engine.searchURL(for: text), let space else {
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
            guard let ext = ExtensionManager.shared.extension(withID: extensionID) else {
                replyHandler(nil, "Extension not found")
                return
            }
            guard offscreenHosts[extensionID] == nil else {
                replyHandler(nil, "Only one offscreen document may be created at a time")
                return
            }

            let host = OffscreenDocumentHost(extensionID: extensionID, basePath: ext.basePath)
            offscreenHosts[extensionID] = host
            host.load(url: url) {
                replyHandler(true, nil)
            }

        case "offscreen.closeDocument":
            offscreenHosts[extensionID]?.stop()
            offscreenHosts.removeValue(forKey: extensionID)
            replyHandler(true, nil)

        case "offscreen.hasDocument":
            let hasDoc = offscreenHosts[extensionID] != nil
            replyHandler(hasDoc, nil)

        // MARK: - Logging Bridge
        case "log":
            let level = params["level"] as? String ?? "info"
            let message = params["message"] as? String ?? ""
            let source = params["source"] as? String ?? extensionID
            switch level {
            case "error": log.error("[SW \(source, privacy: .public)] \(message, privacy: .public)")
            case "warn":  log.warning("[SW \(source, privacy: .public)] \(message, privacy: .public)")
            default:      log.info("[SW \(source, privacy: .public)] \(message, privacy: .public)")
            }
            replyHandler(true, nil)

        default:
            log.warning("Unknown polyfill message type: \(type, privacy: .public)")
            replyHandler(nil, "Unknown polyfill message type: \(type)")
        }
    }

    // MARK: - Helpers

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
