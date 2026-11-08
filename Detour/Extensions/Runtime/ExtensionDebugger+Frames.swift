import Foundation
import WebKit

// TASK-132.15: the frame model of Detour's emulated CDP — `Page.getFrameTree`
// and `Page.frameNavigated`. Only a tab's main frame is modelled.
//
//  - Frame id: one per tab, stable for its life (Chrome's is the frame tree
//    node's devtools token, which a main frame keeps across navigations): the
//    tab's UUID as 32 upper-case hex digits, the shape Chrome's tokens have.
//  - Loader id: one per committed main-frame document, new at every commit
//    (Chrome's is the navigation's token). The Claude extension compares it
//    before and after a screenshot to tell whether the page navigated between.
//  - `Page.frameNavigated` fires once per main-frame commit while the session
//    has Page enabled. Same-document navigations (fragments, pushState) commit
//    nothing in WebKit and fire nothing; Chrome sends
//    `Page.navigatedWithinDocument` for those, which is not emulated.

/// The CDP `Page.Frame` of a tab's main frame, as far as Detour can tell it.
struct ExtensionDebuggerFrame: Equatable {
    var id: String
    var loaderID: String
    var url: URL?
    /// `document.contentType`; "text/html" when the page could not say.
    var mimeType: String = "text/html"
    var isSecureContext: Bool = false
    var isCrossOriginIsolated: Bool = false

    /// The protocol object. `url` carries no fragment; `urlFragment`, with
    /// its `#`, only when there is one, as in Chrome.
    var protocolObject: [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "loaderId": loaderID,
            "url": Self.urlWithoutFragment(url),
            "domainAndRegistry": Self.domainAndRegistry(url),
            "securityOrigin": Self.securityOrigin(url),
            "mimeType": mimeType,
            "secureContextType": Self.secureContextType(url, isSecureContext: isSecureContext),
            "crossOriginIsolatedContextType": isCrossOriginIsolated ? "Isolated" : "NotIsolated",
            "gatedAPIFeatures": isCrossOriginIsolated ? ["SharedArrayBuffers", "SharedArrayBuffersTransferAllowed"] : [],
        ]
        if let fragment = url?.fragment(percentEncoded: true) {
            object["urlFragment"] = "#" + fragment
        }
        return object
    }

    static func urlWithoutFragment(_ url: URL?) -> String {
        guard let text = url?.absoluteString else { return "" }
        if let hash = text.firstIndex(of: "#") { return String(text[..<hash]) }
        return text
    }

    /// The origin serialisation: `scheme://host[:port]` for a tuple origin,
    /// "null" for an opaque one (about:, data:), `file://` for files.
    static func securityOrigin(_ url: URL?) -> String {
        guard let url, let scheme = url.scheme?.lowercased() else { return "null" }
        switch scheme {
        case "http", "https", "ws", "wss":
            guard let host = url.host(percentEncoded: true), !host.isEmpty else { return "null" }
            let defaultPort = (scheme == "http" || scheme == "ws") ? 80 : 443
            let hostText = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            if let port = url.port, port != defaultPort { return "\(scheme)://\(hostText):\(port)" }
            return "\(scheme)://\(hostText)"
        case "file":
            return "file://"
        case "blob":
            return securityOrigin(URL(string: String(url.absoluteString.dropFirst("blob:".count))))
        default:
            // Detour's own schemes and extension pages have tuple origins too.
            if let host = url.host(percentEncoded: true), !host.isEmpty, scheme != "about", scheme != "data" {
                return "\(scheme)://\(host)"
            }
            return "null"
        }
    }

    /// Chrome's registrable domain ("eTLD+1"). Detour has no public suffix
    /// list, so this is the last two labels — right for `example.com`, wrong
    /// for `example.co.uk` (where Chrome says `example.co.uk`) — and empty for
    /// an IP address, a single-label host and a URL without a host, as Chrome.
    static func domainAndRegistry(_ url: URL?) -> String {
        guard let host = url?.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return "" }
        if host.contains(":") { return "" }
        let labels = host.split(separator: ".", omittingEmptySubsequences: true)
        if labels.count < 2 { return "" }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return "" }
        return labels.suffix(2).joined(separator: ".")
    }

    static func secureContextType(_ url: URL?, isSecureContext: Bool) -> String {
        guard isSecureContext else { return "InsecureScheme" }
        let host = url?.host(percentEncoded: false)?.lowercased() ?? ""
        let isLocalhost = host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
        return url?.scheme?.lowercased() == "http" && isLocalhost ? "SecureLocalhost" : "Secure"
    }
}

enum ExtensionDebuggerFrames {

    /// Loader ids by tab, weak on the tab: an entry goes with its tab.
    private static let loaderIDs = NSMapTable<BrowserTab, NSString>.weakToStrongObjects()

    /// What the page said about its document, for the loader id it was read
    /// under: a document's MIME type and security state do not change, and a
    /// page held by a dialog cannot be asked.
    private final class DocumentFacts {
        let loaderID: String
        let mimeType: String
        let isSecureContext: Bool
        let isCrossOriginIsolated: Bool

        init(loaderID: String, mimeType: String, isSecureContext: Bool, isCrossOriginIsolated: Bool) {
            self.loaderID = loaderID
            self.mimeType = mimeType
            self.isSecureContext = isSecureContext
            self.isCrossOriginIsolated = isCrossOriginIsolated
        }
    }
    private static let documentFacts = NSMapTable<BrowserTab, DocumentFacts>.weakToStrongObjects()

    /// The loader id a provisional main-frame load will commit under, by tab:
    /// a document's request reports it before the commit (TASK-132.16).
    private static let provisionalLoaderIDs = NSMapTable<BrowserTab, NSString>.weakToStrongObjects()

    /// A main-frame load started that a debugger reports: the loader id its
    /// document will have.
    static func startProvisionalLoad(for tab: BrowserTab) -> String {
        let token = makeToken()
        provisionalLoaderIDs.setObject(token as NSString, forKey: tab)
        return token
    }

    static func cancelProvisionalLoad(for tab: BrowserTab) {
        provisionalLoaderIDs.removeObject(forKey: tab)
    }

    /// A new CDP-shaped token: 32 upper-case hex digits.
    static func makeToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    static func frameID(for tab: BrowserTab) -> String {
        tab.id.uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// The current document's loader id, made on first use for a document
    /// that committed before anyone asked.
    static func loaderID(for tab: BrowserTab) -> String {
        if let existing = loaderIDs.object(forKey: tab) { return existing as String }
        let token = makeToken()
        loaderIDs.setObject(token as NSString, forKey: tab)
        return token
    }

    /// `BrowserTab.didCommitNavigation()`: a main-frame document committed.
    /// Only tabs a debugger has looked at (or holds) carry a loader id, so
    /// every other tab's commit costs a map lookup.
    static func tabDidCommit(_ tab: BrowserTab) {
        let session = ExtensionDebugger.shared.session(forTabUUID: tab.id)
        let provisional = provisionalLoaderIDs.object(forKey: tab)
        provisionalLoaderIDs.removeObject(forKey: tab)
        guard session != nil || loaderIDs.object(forKey: tab) != nil else { return }
        loaderIDs.setObject(provisional ?? (makeToken() as NSString), forKey: tab)
        guard let session else { return }
        ExtensionDebuggerNetwork.documentDidCommit(tab, loaderID: loaderID(for: tab))
        // Chromium cancels a dialog when its frame navigates away (the
        // dialog manager's kTabNavigated), before the new document reports.
        ExtensionDebuggerDialogs.release(tabUUID: tab.id, emitClosed: true)
        guard session.enabledDomains.contains("Page") else { return }
        let loaderID = loaderID(for: tab)
        Task {
            let frame = await currentFrame(of: tab, loaderID: loaderID)
            // A later commit has its own event; this one is out of date.
            guard self.loaderID(for: tab) == loaderID else { return }
            ExtensionDebugger.shared.emitEvent(session, method: "Page.frameNavigated",
                                               params: ["frame": frame.protocolObject, "type": "Navigation"])
        }
    }

    /// The tab's main frame now. What only the page knows (its MIME type and
    /// security state) is read in Detour's own content world, which the page
    /// can neither see nor answer for — once per document. A page held by a
    /// debugger's dialog runs no script until the dialog is answered, so it is
    /// not asked then (the defaults stand): `Page.getFrameTree` must not wait
    /// on the extension answering a dialog.
    static func currentFrame(of tab: BrowserTab, loaderID: String? = nil) async -> ExtensionDebuggerFrame {
        let loaderID = loaderID ?? self.loaderID(for: tab)
        var frame = ExtensionDebuggerFrame(id: frameID(for: tab), loaderID: loaderID,
                                           url: tab.webView?.url ?? tab.url)
        if let facts = documentFacts.object(forKey: tab), facts.loaderID == loaderID {
            frame.mimeType = facts.mimeType
            frame.isSecureContext = facts.isSecureContext
            frame.isCrossOriginIsolated = facts.isCrossOriginIsolated
            return frame
        }
        if let webView = tab.webView, ExtensionDebuggerDialogs.pendingDialog(forTabUUID: tab.id) == nil {
            let script = "return [document.contentType, isSecureContext, !!globalThis.crossOriginIsolated];"
            if let answer = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil,
                                                                  contentWorld: ExtensionDebugger.contentWorld),
               let values = answer as? [Any], values.count == 3 {
                if let mime = values[0] as? String, !mime.isEmpty { frame.mimeType = mime }
                frame.isSecureContext = (values[1] as? Bool) ?? false
                frame.isCrossOriginIsolated = (values[2] as? Bool) ?? false
                // Only for the document it was read in.
                if self.loaderID(for: tab) == loaderID {
                    documentFacts.setObject(DocumentFacts(loaderID: loaderID, mimeType: frame.mimeType,
                                                          isSecureContext: frame.isSecureContext,
                                                          isCrossOriginIsolated: frame.isCrossOriginIsolated),
                                            forKey: tab)
                }
            }
        }
        return frame
    }

    /// `Page.getFrameTree`: the main frame alone (child frames are not
    /// modelled).
    static func getFrameTree(in session: ExtensionDebuggerSession, reply: ExtensionDebuggerReply) {
        guard let tab = session.tab else {
            reply.fail(code: ExtensionDebugger.serverErrorCode, message: "No frame tree available")
            return
        }
        Task {
            let frame = await currentFrame(of: tab)
            reply.succeed(["frameTree": ["frame": frame.protocolObject] as [String: Any]])
        }
    }
}
