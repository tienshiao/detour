import Combine
import Foundation
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-debugger")

// TASK-132.13: `chrome.debugger`. WebKit has no chrome.debugger and no Chrome
// DevTools Protocol, so Detour emulates the small CDP surface the Claude
// extension drives pages with, natively, one method at a time. This file is the
// attachment model: who holds which tab, Chrome's attach rules and error texts,
// and the lifecycle that ends an attachment (an explicit detach, the tab
// closing, the extension going away, the user pressing Stop). The bridge
// messages are `ExtensionPolyfillHandler+Debugger.swift`; the commands are
// `ExtensionDebugger+Commands.swift` and one file per CDP domain.
//
// Chrome's behaviour, from chrome/browser/extensions/api/debugger/debugger_api.cc:
//  - one debugger per tab: a second `attach` — by any extension, the same one
//    included — fails with "Another debugger is already attached to the tab
//    with id: N.";
//  - an explicit `detach` fires no `onDetach`; neither does the extension
//    unloading (there is no one left to tell);
//  - the tab closing (or navigating somewhere the extension may not attach)
//    fires `onDetach(target_closed)`, the user cancelling it
//    `onDetach(canceled_by_user)`; either way a command still in flight fails
//    with "Detached while handling command.";
//  - a CDP error reaches `runtime.lastError` as the JSON of the protocol's
//    error object, e.g. `{"code":-32601,"message":"'Foo.bar' wasn't found"}`.

/// Why an attachment ended, as `chrome.debugger.onDetach` reports it.
enum ExtensionDebuggerDetachReason: String {
    case targetClosed = "target_closed"
    case canceledByUser = "canceled_by_user"
}

/// A command's reply, answered once: whichever of the command's result and the
/// session ending comes first wins, and the other is dropped.
final class ExtensionDebuggerReply {
    private var handler: ((Any?, String?) -> Void)?
    fileprivate var onFinish: (() -> Void)?

    init(_ handler: @escaping (Any?, String?) -> Void) {
        self.handler = handler
    }

    var isAnswered: Bool { handler == nil }

    /// The command's result object (`{}` for none).
    func succeed(_ result: [String: Any] = [:]) {
        finish(result, nil)
    }

    /// A protocol error, as Chrome reports it: the JSON of `{code, message}`.
    func fail(code: Int, message: String) {
        finish(nil, ExtensionDebugger.protocolError(code: code, message: message))
    }

    /// An error of the `chrome.debugger` API itself (not attached, detached
    /// while handling), passed as is.
    func fail(_ message: String) {
        finish(nil, message)
    }

    private func finish(_ value: Any?, _ error: String?) {
        guard let handler else { return }
        self.handler = nil
        let onFinish = self.onFinish
        self.onFinish = nil
        onFinish?()
        handler(value, error)
    }
}

/// One extension's attachment to one tab.
final class ExtensionDebuggerSession {
    let extensionID: String
    let profileID: UUID
    let tabUUID: UUID
    weak var tab: BrowserTab?
    /// The id the extension's contexts know the tab by — WebKit's tab id, which
    /// is one per tab across an extension's worker and pages. Reported by the
    /// attaching context, and how later calls name the session.
    let tabID: Int
    /// CDP domains the extension enabled (`Page.enable`, …): a domain's events
    /// are sent only while it is enabled, as in Chrome.
    var enabledDomains: Set<String> = []
    /// `Network.enable`'s `maxPostDataSize`: the longest request body, in
    /// bytes, a `requestWillBeSent` carries (TASK-132.16).
    var maxPostDataSize = 0
    /// Commands still being handled, failed with "Detached while handling
    /// command." if the session ends first.
    fileprivate var pending: [ObjectIdentifier: ExtensionDebuggerReply] = [:]
    fileprivate var urlObservation: AnyCancellable?

    var owner: TabAutomationOwner {
        TabAutomationOwner(extensionID: extensionID, reason: ExtensionDebugger.automationReason)
    }

    init(extensionID: String, profileID: UUID, tab: BrowserTab, tabID: Int) {
        self.extensionID = extensionID
        self.profileID = profileID
        self.tabUUID = tab.id
        self.tab = tab
        self.tabID = tabID
    }

    /// Records a reply as in flight until it is answered.
    func track(_ reply: ExtensionDebuggerReply) {
        let key = ObjectIdentifier(reply)
        pending[key] = reply
        reply.onFinish = { [weak self] in self?.pending[key] = nil }
    }

    var pendingCount: Int { pending.count }
}

/// Every debugger attachment in the process, keyed by tab.
final class ExtensionDebugger {

    static let shared = ExtensionDebugger()

    /// `TabAutomationOwner.reason` of a debugger attachment.
    static let automationReason = "debugger"

    // MARK: Chrome's texts

    static func alreadyAttachedError(tabID: Int) -> String {
        "Another debugger is already attached to the tab with id: \(tabID)."
    }
    static func noTabError(_ tabID: Any?) -> String {
        "No tab with given id \(tabID.map { "\($0)" } ?? "undefined")."
    }
    static func notAttachedError(tabID: Int) -> String {
        "Debugger is not attached to the tab with id: \(tabID)."
    }
    static func unsupportedVersionError(_ version: String) -> String {
        "Requested protocol version is not supported: \(version)."
    }
    static let restrictedError = "Cannot attach to this target."
    static let detachedWhileHandlingError = "Detached while handling command."
    static let galleryError = "The extensions gallery cannot be scripted."
    static let otherExtensionPageError = "Cannot access a \(ExtensionPageURL.scheme):// URL of different extension"
    static func restrictedSchemeError(_ scheme: String) -> String {
        "Cannot access a \(scheme):// URL"
    }

    /// CDP's own error codes.
    static let methodNotFoundCode = -32601
    static let invalidParamsCode = -32602
    static let serverErrorCode = -32000

    /// A protocol error the way Chrome hands it to `runtime.lastError`.
    static func protocolError(code: Int, message: String) -> String {
        let object: [String: Any] = ["code": code, "message": message]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"code\":\(code),\"message\":\"\(message)\"}"
        }
        // Chrome writes `code` first; sorted keys give the same order.
        return text
    }

    static func methodNotFound(_ method: String) -> (code: Int, message: String) {
        (methodNotFoundCode, "'\(method)' wasn't found")
    }

    // MARK: Rules

    /// Chrome's `DevToolsAgentHost::IsSupportedProtocolVersion`: "1.0" to "1.3".
    static func isSupportedProtocolVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]) else { return false }
        return major == 1 && minor <= 3
    }

    /// The host of the store whose pages Chrome lets no extension script.
    static let galleryHost = "chromewebstore.google.com"

    /// Why an extension may not attach to (or stay attached to) a page at
    /// `url`, or nil when it may — Chrome's `ExtensionMayAttachToURL`. The
    /// `debugger` permission implies access to every site, so no host
    /// permission is checked; what is refused is what no extension may touch:
    /// Detour's own pages (`detour://` and its other internal schemes),
    /// another extension's pages, and the extension gallery. Blank pages, web
    /// pages, files, data and blob URLs, and Detour's error page (Chrome allows
    /// its own) are fine.
    ///
    /// `ownExtensionHost` is the host of the extension's own base URL
    /// (`webkit-extension://<host>/`): its own pages are allowed, as in Chrome.
    static func attachRefusal(for url: URL?, ownExtensionHost: String?) -> String? {
        guard let url, let rawScheme = url.scheme, !rawScheme.isEmpty else { return nil }
        let scheme = rawScheme.lowercased()
        switch scheme {
        case "about", "http", "https", "file", "data", ErrorPage.scheme:
            if (scheme == "http" || scheme == "https"), url.host?.lowercased() == galleryHost { return galleryError }
            return nil
        case "blob":
            // A blob URL is judged by the origin that made it.
            let inner = URL(string: String(url.absoluteString.dropFirst("blob:".count)))
            return attachRefusal(for: inner, ownExtensionHost: ownExtensionHost)
        case ExtensionPageURL.scheme:
            if let ownExtensionHost, let host = url.host, host.caseInsensitiveCompare(ownExtensionHost) == .orderedSame {
                return nil
            }
            return otherExtensionPageError
        default:
            return restrictedSchemeError(scheme)
        }
    }

    // MARK: State

    /// Sessions by tab: at most one per tab.
    private(set) var sessions: [UUID: ExtensionDebuggerSession] = [:]
    /// Each profile's event channel, registered by its polyfill handler.
    private var channels: [UUID: WeakChannel] = [:]
    private var permissionObserver: NSObjectProtocol?

    private struct WeakChannel {
        weak var parking: ExtensionEventParking?
    }

    /// The window and the sidebar learn about an attachment from
    /// `BrowserTab.automationOwners`; Stop comes back here.
    private init() {
        permissionObserver = NotificationCenter.default.addMainObserver(
            forName: ExtensionManager.permissionDecisionsDidChangeNotification, object: nil
        ) { notification in
            let extensionID = notification.userInfo?[ExtensionManager.extensionIDUserInfoKey] as? String
            ExtensionDebugger.shared.permissionsMayHaveChanged(extensionID: extensionID)
        }
    }

    /// What the user's Stop does to a debugger attachment: Chrome's infobar
    /// Cancel. Registered at every attach, so it is there whenever an
    /// attachment is.
    private func registerStopHandler() {
        TabAutomationStop.register(reason: Self.automationReason) { tab, owner in
            ExtensionDebugger.shared.end(tabUUID: tab.id, extensionID: owner.extensionID, reason: .canceledByUser)
        }
    }

    /// Where `profileID`'s debugger events go.
    func register(channel: ExtensionEventParking, for profileID: UUID) {
        channels[profileID] = WeakChannel(parking: channel)
    }

    func session(forTabUUID tabUUID: UUID) -> ExtensionDebuggerSession? {
        sessions[tabUUID]
    }

    /// The session `extensionID` holds on the tab it knows as `tabID`, in
    /// `profileID`.
    func session(extensionID: String, profileID: UUID, tabID: Int) -> ExtensionDebuggerSession? {
        sessions.values.first { $0.extensionID == extensionID && $0.profileID == profileID && $0.tabID == tabID }
    }

    func sessions(extensionID: String, profileID: UUID) -> [ExtensionDebuggerSession] {
        sessions.values.filter { $0.extensionID == extensionID && $0.profileID == profileID }
    }

    // MARK: Attach and detach

    enum AttachOutcome: Equatable {
        case attached
        case refused(String)
    }

    /// Attaches `extensionID` to `tab`, which its contexts know as `tabID`.
    /// The caller has checked the permission, the protocol version and that
    /// the tab is the extension's profile's; this checks the page and that the
    /// tab is free, then makes the tab automation-attached (woken, and parked
    /// when no window shows it).
    func attach(extensionID: String, profileID: UUID, tab: BrowserTab, tabID: Int,
                ownExtensionHost: String?) -> AttachOutcome {
        if sessions[tab.id] != nil {
            return .refused(Self.alreadyAttachedError(tabID: tabID))
        }
        if let refusal = Self.attachRefusal(for: tab.url, ownExtensionHost: ownExtensionHost) {
            return .refused(refusal)
        }
        // A stale session naming the same id (WebKit gave a re-registered tab
        // a new id and this one an old one) would shadow the new attachment.
        if let stale = session(extensionID: extensionID, profileID: profileID, tabID: tabID) {
            end(stale, reason: .targetClosed)
        }
        let session = ExtensionDebuggerSession(extensionID: extensionID, profileID: profileID, tab: tab, tabID: tabID)
        registerStopHandler()
        guard tab.attachAutomation(session.owner) else {
            return .refused(Self.noTabError(tabID))
        }
        sessions[tab.id] = session
        // Console and request reports, for Runtime and Network (TASK-132.16).
        ExtensionDebuggerInstrumentation.sessionDidStart(session)
        // Navigating somewhere the extension may not be ends the attachment, as
        // Chrome's client host does on a navigation it may not follow.
        session.urlObservation = tab.$url.dropFirst().sink { [weak self, weak tab] url in
            guard let tab, Self.attachRefusal(for: url, ownExtensionHost: ownExtensionHost) != nil else { return }
            // `$url` publishes before the property is set: settle on the next
            // turn so nothing reads a half-updated tab.
            DispatchQueue.main.async {
                guard let self, self.sessions[tab.id] === session else { return }
                self.end(session, reason: .targetClosed)
            }
        }
        log.info("Debugger attached: \(extensionID, privacy: .public) to a tab")
        return .attached
    }

    /// Ends `session` and releases the tab. With a `reason` the extension is
    /// told (`onDetach`); without one (its own `detach`, or it went away) it
    /// is not, as in Chrome. Commands in flight fail either way.
    func end(_ session: ExtensionDebuggerSession, reason: ExtensionDebuggerDetachReason?) {
        guard sessions[session.tabUUID] === session else { return }
        sessions[session.tabUUID] = nil
        session.urlObservation = nil
        let pending = Array(session.pending.values)
        session.pending.removeAll()
        for reply in pending { reply.fail(Self.detachedWhileHandlingError) }
        session.tab?.detachAutomation(session.owner)
        ExtensionDebuggerSessionEndObservers.notify(session)
        if let reason {
            emit(to: session, ["kind": "detach", "tabId": session.tabID, "reason": reason.rawValue])
        }
        log.info("Debugger detached: \(session.extensionID, privacy: .public) (\(reason?.rawValue ?? "by the extension", privacy: .public))")
    }

    /// Ends `extensionID`'s session on the tab with `tabUUID`, if it holds one.
    func end(tabUUID: UUID, extensionID: String, reason: ExtensionDebuggerDetachReason?) {
        guard let session = sessions[tabUUID], session.extensionID == extensionID else { return }
        end(session, reason: reason)
    }

    // MARK: Events

    /// Sends a CDP event to the session's extension (`chrome.debugger.onEvent`),
    /// if it enabled the event's domain.
    func emitEvent(_ session: ExtensionDebuggerSession, method: String, params: [String: Any]) {
        guard sessions[session.tabUUID] === session else { return }
        let domain = String(method.prefix { $0 != "." })
        guard session.enabledDomains.contains(domain) else { return }
        emit(to: session, ["kind": "event", "tabId": session.tabID, "method": method, "params": params])
    }

    private func emit(to session: ExtensionDebuggerSession, _ payload: [String: Any]) {
        guard let channel = channels[session.profileID]?.parking else { return }
        channel.deliver(payload, toExtension: session.extensionID)
    }

    // MARK: Lifecycle

    /// The tab closed, or left the extension's view (moved to another
    /// profile's space, put to sleep as a Peek): `ExtensionTabLifecycle.didClose`.
    func tabDidClose(_ tab: BrowserTab) {
        guard let session = sessions[tab.id] else { return }
        end(session, reason: .targetClosed)
    }

    /// The extension's context in `profileID` is going away (disabled,
    /// removed, reloaded, the profile closing): nothing is left to tell.
    func extensionWillUnload(_ extensionID: String, profileID: UUID) {
        for session in sessions(extensionID: extensionID, profileID: profileID) {
            end(session, reason: nil)
        }
    }

    /// A Settings switch changed: an extension whose `debugger` permission is
    /// no longer active loses its attachments, told as a user cancel.
    private func permissionsMayHaveChanged(extensionID: String?) {
        for session in Array(sessions.values) where extensionID == nil || session.extensionID == extensionID {
            if permissionRefusal(for: session) != nil {
                end(session, reason: .canceledByUser)
            }
        }
    }

    /// Why the session's extension may not use the debugger now, or nil.
    func permissionRefusal(for session: ExtensionDebuggerSession) -> String? {
        guard let ext = ExtensionManager.shared.extension(withID: session.extensionID) else {
            return ExtensionPolyfillHandler.permissionNotDeclared("debugger")
        }
        let context = TabStore.shared.profiles.first { $0.id == session.profileID }?
            .extensionContext(for: session.extensionID)
        return ExtensionPolyfillHandler.permissionRefusal("debugger", manifest: ext.manifest, context: context)
    }

    #if DEBUG
    /// Ends every session silently, for tests.
    func resetForTesting() {
        for session in Array(sessions.values) { end(session, reason: nil) }
        channels.removeAll()
    }
    #endif
}

/// Things that hold per-session state elsewhere (a pending dialog, a console
/// buffer — TASK-132.15/16) and must let it go when a session ends.
enum ExtensionDebuggerSessionEndObservers {
    private static var observers: [(ExtensionDebuggerSession) -> Void] = []

    static func add(_ observer: @escaping (ExtensionDebuggerSession) -> Void) {
        observers.append(observer)
    }

    fileprivate static func notify(_ session: ExtensionDebuggerSession) {
        for observer in observers { observer(session) }
    }
}
