import Foundation
import WebKit

/// Routes messages between content scripts, background scripts, and native code.
/// Registered as `WKScriptMessageHandler` for the "extensionMessage" handler name.
class ExtensionMessageBridge: NSObject, WKScriptMessageHandler {
    static let shared = ExtensionMessageBridge()
    static let handlerName = "extensionMessage"

    private override init() {
        super.init()
    }

    /// Register the bridge on a WKUserContentController. Safe to call multiple times.
    func register(on controller: WKUserContentController) {
        controller.add(self, name: Self.handlerName)
    }

    /// Register the bridge on a WKUserContentController in a specific content world.
    func register(on controller: WKUserContentController, contentWorld: WKContentWorld) {
        controller.add(self, contentWorld: contentWorld, name: Self.handlerName)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let extensionID = body["extensionID"] as? String,
              let type = body["type"] as? String else { return }

        switch type {
        case "runtime.sendMessage":
            handleSendMessage(body: body, extensionID: extensionID, sourceWebView: message.webView)

        case "runtime.sendResponse":
            handleSendResponse(body: body, extensionID: extensionID)

        case "storage.get":
            handleStorageGet(body: body, extensionID: extensionID, sourceWebView: message.webView)

        case "storage.set":
            handleStorageSet(body: body, extensionID: extensionID, sourceWebView: message.webView)

        case "storage.remove":
            handleStorageRemove(body: body, extensionID: extensionID, sourceWebView: message.webView)

        case "storage.clear":
            handleStorageClear(body: body, extensionID: extensionID, sourceWebView: message.webView)

        default:
            print("[ExtensionBridge] Unknown message type: \(type)")
        }
    }

    // MARK: - Message Routing

    private func handleSendMessage(body: [String: Any], extensionID: String, sourceWebView: WKWebView?) {
        guard let message = body["message"],
              let callbackID = body["callbackID"] as? String else { return }

        guard let ext = ExtensionManager.shared.extension(withID: extensionID),
              let backgroundHost = ExtensionManager.shared.backgroundHost(for: extensionID) else { return }

        // Serialize message to JSON for transport
        guard let messageData = try? JSONSerialization.data(withJSONObject: message),
              let messageJSON = String(data: messageData, encoding: .utf8) else { return }

        let sender: [String: Any] = [
            "id": extensionID,
            "origin": "content-script"
        ]
        guard let senderData = try? JSONSerialization.data(withJSONObject: sender),
              let senderJSON = String(data: senderData, encoding: .utf8) else { return }

        // Dispatch to background script in .page world
        let js = "window.__extensionDispatchMessage(\(messageJSON), \(senderJSON), '\(callbackID)');"
        backgroundHost.evaluateJavaScript(js) { _, error in
            if let error {
                print("[ExtensionBridge] Error dispatching to background: \(error)")
            }
        }

        // Store the source webView to route the response back
        pendingResponses[callbackID] = PendingResponse(
            sourceWebView: sourceWebView,
            contentWorld: ext.contentWorld
        )
    }

    private func handleSendResponse(body: [String: Any], extensionID: String) {
        guard let callbackID = body["callbackID"] as? String,
              let pending = pendingResponses.removeValue(forKey: callbackID) else { return }

        let response = body["response"] ?? [String: Any]()
        guard let responseData = try? JSONSerialization.data(withJSONObject: response),
              let responseJSON = String(data: responseData, encoding: .utf8) else { return }

        let js = "window.__extensionDeliverResponse('\(callbackID)', \(responseJSON));"

        if let webView = pending.sourceWebView {
            webView.evaluateJavaScript(js, in: nil, in: pending.contentWorld) { _ in }
        }
    }

    // MARK: - Storage Handlers

    private func handleStorageGet(body: [String: Any], extensionID: String, sourceWebView: WKWebView?) {
        guard let params = body["params"] as? [String: Any],
              let callbackID = body["callbackID"] as? String else { return }
        let isContentScript = body["isContentScript"] as? Bool ?? true

        let getAll = params["getAll"] as? Bool ?? false
        let result: [String: Any]
        if getAll {
            result = ExtensionDatabase.shared.storageGetAll(extensionID: extensionID)
        } else {
            let keys = params["keys"] as? [String] ?? []
            result = ExtensionDatabase.shared.storageGet(extensionID: extensionID, keys: keys)
        }

        deliverCallbackResponse(callbackID: callbackID, result: result, extensionID: extensionID, webView: sourceWebView, isContentScript: isContentScript)
    }

    private func handleStorageSet(body: [String: Any], extensionID: String, sourceWebView: WKWebView?) {
        guard let params = body["params"] as? [String: Any],
              let items = params["items"] as? [String: Any],
              let callbackID = body["callbackID"] as? String else { return }
        let isContentScript = body["isContentScript"] as? Bool ?? true

        ExtensionDatabase.shared.storageSet(extensionID: extensionID, items: items)
        deliverCallbackResponse(callbackID: callbackID, result: [:], extensionID: extensionID, webView: sourceWebView, isContentScript: isContentScript)
    }

    private func handleStorageRemove(body: [String: Any], extensionID: String, sourceWebView: WKWebView?) {
        guard let params = body["params"] as? [String: Any],
              let keys = params["keys"] as? [String],
              let callbackID = body["callbackID"] as? String else { return }
        let isContentScript = body["isContentScript"] as? Bool ?? true

        ExtensionDatabase.shared.storageRemove(extensionID: extensionID, keys: keys)
        deliverCallbackResponse(callbackID: callbackID, result: [:], extensionID: extensionID, webView: sourceWebView, isContentScript: isContentScript)
    }

    private func handleStorageClear(body: [String: Any], extensionID: String, sourceWebView: WKWebView?) {
        guard let callbackID = body["callbackID"] as? String else { return }
        let isContentScript = body["isContentScript"] as? Bool ?? true

        ExtensionDatabase.shared.storageClear(extensionID: extensionID)
        deliverCallbackResponse(callbackID: callbackID, result: [:], extensionID: extensionID, webView: sourceWebView, isContentScript: isContentScript)
    }

    private func deliverCallbackResponse(callbackID: String, result: [String: Any], extensionID: String, webView: WKWebView?, isContentScript: Bool) {
        guard let webView else { return }

        guard let resultData = try? JSONSerialization.data(withJSONObject: result),
              let resultJSON = String(data: resultData, encoding: .utf8) else { return }

        let js = "window.__extensionDeliverResponse('\(callbackID)', \(resultJSON));"

        // Deliver to the same world the request came from.
        // Content scripts run in an isolated content world; popups/background run in .page.
        if isContentScript, let ext = ExtensionManager.shared.extension(withID: extensionID) {
            webView.evaluateJavaScript(js, in: nil, in: ext.contentWorld) { _ in }
        } else {
            webView.evaluateJavaScript(js) { _, _ in }
        }
    }

    // MARK: - Pending Response Tracking

    private struct PendingResponse {
        weak var sourceWebView: WKWebView?
        let contentWorld: WKContentWorld
    }

    private var pendingResponses: [String: PendingResponse] = [:]
}
