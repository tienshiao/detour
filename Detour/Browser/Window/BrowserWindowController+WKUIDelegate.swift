import AppKit
import WebKit

extension BrowserWindowController: WKUIDelegate {

    // MARK: - window.open() and context menu link actions

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url, let space = activeSpace else { return nil }

        switch contextMenuLinkAction {
        case .openInNewTab:
            contextMenuLinkAction = .none
            _ = TabStore.shared.addTab(in: space, url: url, afterTabID: selectedTabID)
        case .openInNewWindow:
            contextMenuLinkAction = .none
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.createNewWindowWithURL(url)
            }
        case .none:
            let tab = TabStore.shared.addTab(in: space, url: url, afterTabID: selectedTabID)
            selectTab(id: tab.id)
        }

        return nil
    }

    // MARK: - JavaScript Dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")

        if let window = self.window {
            alert.beginSheetModal(for: window) { _ in
                completionHandler()
            }
        } else {
            completionHandler()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        if let window = self.window {
            alert.beginSheetModal(for: window) { response in
                completionHandler(response == .alertFirstButtonReturn)
            }
        } else {
            completionHandler(false)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(frame.securityOrigin.host) says"
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = defaultText ?? ""
        alert.accessoryView = textField

        if let window = self.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    completionHandler(textField.stringValue)
                } else {
                    completionHandler(nil)
                }
            }
        } else {
            completionHandler(nil)
        }
    }

    // MARK: - Window Close

    func webView(_ webView: WKWebView, didClose: WKWebView) {
        let store = TabStore.shared
        for space in store.spaces {
            if let tab = space.tabs.first(where: { $0.webView === webView }) {
                store.closeTab(id: tab.id, in: space)
                return
            }
        }
    }

    // MARK: - File Upload

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories

        if let window = self.window {
            panel.beginSheetModal(for: window) { response in
                if response == .OK {
                    completionHandler(panel.urls)
                } else {
                    completionHandler(nil)
                }
            }
        } else {
            completionHandler(nil)
        }
    }

    // MARK: - Media Capture Permission

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let mediaType: String
        switch type {
        case .camera: mediaType = "camera"
        case .microphone: mediaType = "microphone"
        case .cameraAndMicrophone: mediaType = "camera and microphone"
        @unknown default: mediaType = "media"
        }

        let alert = NSAlert()
        alert.messageText = "Allow \(originString(from: origin)) to access your \(mediaType)?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")

        if let window = self.window {
            alert.beginSheetModal(for: window) { response in
                decisionHandler(response == .alertFirstButtonReturn ? .grant : .deny)
            }
        } else {
            decisionHandler(.deny)
        }
    }

    // MARK: - Private Helpers

    private func originString(from origin: WKSecurityOrigin) -> String {
        if origin.port != 0 {
            return "\(origin.protocol)://\(origin.host):\(origin.port)"
        }
        return "\(origin.protocol)://\(origin.host)"
    }
}
