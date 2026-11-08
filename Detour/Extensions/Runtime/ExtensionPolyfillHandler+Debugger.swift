import Foundation
import WebKit

// TASK-132.13: the native half of `chrome.debugger` (`ExtensionAPIPolyfill.debuggerJS`).
// The attachment model and Chrome's rules are `ExtensionDebugger`; the CDP
// commands `ExtensionDebugger+Commands.swift`.
//
// The polyfill names a tab two ways. `attach` sends the tab's handle from the
// tab-id bridge (`__detourResolveTab`) together with the WebKit tab id the
// extension used; every later call (`detach`, `sendCommand`) and every event
// names the tab by that id alone, so a command costs no bridge round trip and
// an event reaches a context that never resolved the tab. The id is only ever
// matched against this extension's own sessions in this profile.

extension ExtensionPolyfillHandler {

    static let debuggerPermissionRefusal = "debugger: the extension does not declare the debugger permission"

    /// Every `debugger.*` bridge message.
    func handleDebuggerRequest(_ type: String, params: [String: Any], extensionID: String,
                               sender: PolyfillSender, senderWebView: WKWebView?,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        // WebKit vends no debugger and does not know the permission, so the
        // manifest — and a denial in this profile's context — is the gate.
        // An event wait is refused only when the permission is not declared:
        // a denial ends the attachments (onDetach canceled_by_user), and a
        // context whose next wait were refused would stop listening for good,
        // missing every event after the switch is turned back on. Nothing
        // reaches a wait without an attachment, which the gate still guards.
        if let refusal = permissionRefusal("debugger", extensionID: extensionID) {
            let undeclared = refusal == Self.permissionNotDeclared("debugger")
            if undeclared || type != "debugger.awaitEvent" {
                replyHandler(nil, undeclared ? Self.debuggerPermissionRefusal : refusal)
                return
            }
        }
        guard let profile else {
            replyHandler(nil, "\(type): profile unavailable")
            return
        }
        let debugger = ExtensionDebugger.shared
        // Every profile whose extensions use the debugger has a channel, before
        // anything could need to tell them about a detach.
        _ = debuggerEventChannel(for: profile)

        switch type {
        case "debugger.attach":
            guard let tabID = Self.integer(params["tabId"]) else {
                replyHandler(nil, ExtensionDebugger.noTabError(params["tabId"]))
                return
            }
            let version = params["version"] as? String ?? ""
            guard ExtensionDebugger.isSupportedProtocolVersion(version) else {
                replyHandler(nil, ExtensionDebugger.unsupportedVersionError(version))
                return
            }
            let resolved: ExtensionTabHandleRegistry.ResolvedTab
            switch resolveTabHandle(params["tabHandle"]) {
            case .failure(let error):
                _ = Self.tabHandleRefusal(error, type: type)
                replyHandler(nil, ExtensionDebugger.noTabError(tabID))
                return
            case .success(let tab):
                resolved = tab
            }
            let ownHost = profile.extensionContext(for: extensionID)?.baseURL.host
            switch debugger.attach(extensionID: extensionID, profileID: profile.id, tab: resolved.tab,
                                   tabID: tabID, ownExtensionHost: ownHost) {
            case .attached: replyHandler(NSNull(), nil)
            case .refused(let message): replyHandler(nil, message)
            }

        case "debugger.detach":
            guard let tabID = Self.integer(params["tabId"]) else {
                replyHandler(nil, ExtensionDebugger.noTabError(params["tabId"]))
                return
            }
            guard let session = debugger.session(extensionID: extensionID, profileID: profile.id, tabID: tabID) else {
                replyHandler(nil, ExtensionDebugger.notAttachedError(tabID: tabID))
                return
            }
            debugger.end(session, reason: nil)
            replyHandler(NSNull(), nil)

        case "debugger.sendCommand":
            guard let tabID = Self.integer(params["tabId"]) else {
                replyHandler(nil, ExtensionDebugger.noTabError(params["tabId"]))
                return
            }
            guard let session = debugger.session(extensionID: extensionID, profileID: profile.id, tabID: tabID) else {
                replyHandler(nil, ExtensionDebugger.notAttachedError(tabID: tabID))
                return
            }
            guard let method = params["method"] as? String, !method.isEmpty else {
                replyHandler(nil, "debugger.sendCommand: method must be a non-empty string")
                return
            }
            let commandParams = params["params"] as? [String: Any] ?? [:]
            debugger.run(method, params: commandParams, in: session, reply: ExtensionDebuggerReply { value, error in
                replyHandler(value, error)
            })

        case "debugger.targets":
            // The tabs the context listed (`tabs.query({})`), resolved to
            // handles there; a handle that does not resolve here — closed since,
            // or another profile's — is left out.
            let entries = params["tabs"] as? [Any] ?? []
            var targets: [[String: Any]] = []
            for case let entry as [String: Any] in entries {
                guard let tabID = Self.integer(entry["tabId"]),
                      case .success(let resolved) = resolveTabHandle(entry["handle"]) else { continue }
                let tab = resolved.tab
                var target: [String: Any] = [
                    "tabId": tabID,
                    "handle": ExtensionTabHandleRegistry.shared.handle(for: tab),
                    // By anyone, as in Chrome: one debugger per tab.
                    "attached": debugger.session(forTabUUID: tab.id) != nil,
                    "title": tab.title,
                    "url": tab.url?.absoluteString ?? "",
                ]
                if let favicon = tab.faviconURL?.absoluteString { target["faviconUrl"] = favicon }
                targets.append(target)
            }
            replyHandler(["targets": targets] as [String: Any], nil)

        case "debugger.awaitEvent":
            let channel = debuggerEventChannel(for: profile)
            let registered = ExtensionManager.shared.extension(withID: extensionID)
            let isBackground = Self.senderIsBackgroundContext(sender, background: registered?.manifest.background)
            channel.awaitEvent(extensionID: extensionID, isBackground: isBackground,
                               instance: params["instance"] as? String,
                               webView: isBackground ? nil : senderWebView,
                               ack: (params["ack"] as? NSNumber)?.intValue, reply: replyHandler)

        default:
            replyHandler(nil, "Unknown polyfill message type: \(type)")
        }
    }

    // MARK: Helpers

    /// The channel `chrome.debugger` events reach this profile's contexts
    /// through, made on first use and registered with `ExtensionDebugger`.
    func debuggerEventChannel(for profile: Profile) -> ExtensionEventParking {
        if let existing = debuggerEvents { return existing }
        let channel = ExtensionEventParking(
            label: "debugger events", backlogLimit: 1000,
            supersededError: "debugger events: superseded by a newer wait",
            unloadedError: "debugger events: the extension was unloaded",
            wakeBackground: { [weak profile] extensionID in
                guard let context = profile?.extensionContext(for: extensionID),
                      context.webExtension.hasBackgroundContent else { return }
                context.loadBackgroundContent { _ in }
            })
        debuggerEvents = channel
        ExtensionDebugger.shared.register(channel: channel, for: profile.id)
        return channel
    }

    /// A whole JS number, not a boolean.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }
}
