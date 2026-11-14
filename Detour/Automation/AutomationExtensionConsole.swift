import Foundation
import WebKit

/// The console of extension contexts for `console_messages` (TASK-228.2):
/// what the polyfill's console bridge sends from the background worker, the
/// popup, the options page and other extension pages, with uncaught errors
/// and unhandled rejections, recorded per extension and profile while the
/// endpoint is on. Same entry shape and `seq` cursor as a tab's console
/// (`AutomationPageCapture`), plus `context_kind` (worker, popup, options or
/// page) and `context` (the context string a client names it by).
///
/// The bridge already runs in every extension context; this only keeps what
/// it sends, before the os_log path's cap (`ConsoleBridgeLimiter`). What the
/// bridge's own in-page limiter collapses or drops (more than 50 messages at
/// once, more than 20 a second, repeats as "(repeated N times)") never
/// arrives. `console.debug` is not bridged. Never for the Private profile.
final class AutomationExtensionConsole {

    static let shared = AutomationExtensionConsole()

    struct Key: Hashable {
        let extensionID: String
        let profileID: UUID
    }

    /// Whether the endpoint is on, so the bridge's messages are kept.
    private(set) var isActive = false
    private var buffers: [Key: AutomationRingBuffer] = [:]

    func start() { isActive = true }

    func stop() {
        isActive = false
        buffers.removeAll()
    }

    func buffer(extensionID: String, profileID: UUID) -> AutomationRingBuffer? {
        buffers[Key(extensionID: extensionID, profileID: profileID)]
    }

    /// Forgets an uninstalled extension's records.
    func forget(extensionID: String) {
        buffers = buffers.filter { $0.key.extensionID != extensionID }
    }

    /// Records one bridged `log` message. `params` is the bridge's: `level`,
    /// `message`, and from this build on `consoleLevel`, `origin`, `stack`,
    /// `sourceURL`, `line`, `column`.
    func record(extensionID: String, profile: Profile, sender: ExtensionPolyfillHandler.PolyfillSender,
                webView: WKWebView?, params: [String: Any]) {
        guard isActive, !profile.isIncognito else { return }
        let kind = Self.contextKind(extensionID: extensionID, profile: profile, sender: sender, webView: webView)
        // The compatibility report's own probe page is not the extension's.
        guard kind != Self.probeKind else { return }
        let bridged = params["level"] as? String
        let level = Self.pick(params["consoleLevel"], from: AutomationPageCapture.consoleLevels,
                              else: bridged == "warn" || bridged == "error" ? bridged! : "info")
        let source = Self.pick(params["origin"], from: AutomationPageCapture.consoleSources, else: "console")
        var frameURL: String?
        var mainFrame = true
        if case .frame(let url, let isMainFrame, _) = sender {
            frameURL = url?.absoluteString
            mainFrame = isMainFrame
        }
        let context = kind == "page" ? nil : "\(kind):\(extensionID)"
        let fields: [String: JSONValue] = [
            "level": .string(level),
            "source": .string(source),
            "text": .string(Self.text(params["message"]) ?? ""),
            "stack": .nullable(Self.text(params["stack"])),
            "source_url": .nullable(Self.text(params["sourceURL"])),
            "line": Self.number(params["line"]),
            "column": Self.number(params["column"]),
            "frame_url": .nullable(frameURL),
            "main_frame": .bool(mainFrame),
            "context_kind": .string(kind),
            "context": .nullable(context),
            "extension_id": .string(extensionID),
            "timestamp": .int(Int(Date().timeIntervalSince1970 * 1000)),
        ]
        let key = Key(extensionID: extensionID, profileID: profile.id)
        var buffer = buffers[key] ?? AutomationRingBuffer(capacity: AutomationPageCapture.capacity)
        buffer.append(category: level, fields: fields)
        buffers[key] = buffer
    }

    /// The kind of the compatibility report's probe page
    /// (`AutomationExtensionProbePages`), whose messages are not recorded.
    static let probeKind = "probe"

    /// Which context a bridged message came from: `worker` (the service
    /// worker, or a background page), `popup`, `options`, `probe` (the
    /// compatibility report's own page), or `page` (any other extension
    /// page: a tab, an offscreen document, a frame).
    static func contextKind(extensionID: String, profile: Profile, sender: ExtensionPolyfillHandler.PolyfillSender,
                            webView: WKWebView?) -> String {
        let background = ExtensionManager.shared.extension(withID: extensionID)?.manifest.background
        if ExtensionPolyfillHandler.senderIsBackgroundContext(sender, background: background) { return "worker" }
        guard let webView else { return "page" }
        if AutomationExtensionProbePages.shared.isProbe(webView) { return probeKind }
        if AutomationExtensionPopups.shared.isPopup(webView)
            || ExtensionManager.shared.extensionOpenedPopupWebView(extensionID: extensionID) === webView {
            return "popup"
        }
        if let context = profile.extensionContext(for: extensionID), let optionsURL = context.optionsPageURL,
           ExtensionManager.isOptionsPage(webView.url, optionsURL: optionsURL, baseURL: context.baseURL) {
            return "options"
        }
        return "page"
    }

    private static func pick(_ value: Any?, from allowed: Set<String>, else fallback: String) -> String {
        guard let string = value as? String, allowed.contains(string) else { return fallback }
        return string
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let limit = AutomationPageCapture.maximumTextLength
        return string.count > limit ? String(string.prefix(limit)) + "…" : string
    }

    private static func number(_ value: Any?) -> JSONValue {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return .null }
        return .int(number.intValue)
    }
}
