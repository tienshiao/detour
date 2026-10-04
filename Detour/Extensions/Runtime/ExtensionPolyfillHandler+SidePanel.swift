import AppKit
import WebKit

// TASK-132.8: the native half of `chrome.sidePanel`
// (`ExtensionAPIPolyfill.sidePanelJS`). The state and the panels belong to the
// profile's `ExtensionSidePanelController`; this only turns a bridge message
// into a call on it.

extension ExtensionPolyfillHandler {

    static let sidePanelPermissionRefusal = "sidePanel: the extension does not declare the sidePanel permission"

    /// Every `sidePanel.*` bridge message.
    ///
    /// A tab arrives as a handle (`tabHandle`, what the polyfill's
    /// `__detourResolveTab(tabId)` resolved the WebKit tab id to) and is
    /// refused unless it is a tab this profile lists. A window cannot arrive at
    /// all — there is no bridge from WebKit's window ids — so the polyfill
    /// names it by its active tab (`windowTabHandle`); see `sidePanelWindow`.
    func handleSidePanelRequest(_ type: String, params: [String: Any], extensionID: String,
                                sender: PolyfillSender, senderWebView: WKWebView?,
                                replyHandler: @escaping (Any?, String?) -> Void) {
        // WebKit does not know the permission (it is absent from
        // `WKWebExtension.requestedPermissions`), so the manifest is the gate —
        // here as in the polyfill, which defines no `chrome.sidePanel` without it.
        guard hasPermission("sidePanel", extensionID: extensionID) else {
            replyHandler(nil, Self.sidePanelPermissionRefusal)
            return
        }
        guard let profile else {
            replyHandler(nil, "\(type): profile unavailable")
            return
        }
        let panels = profile.sidePanels

        if type == "sidePanel.closeSelf" {
            // A panel's page called `window.close()`. Only the panel's own
            // top-level document closes it; from any other page this is a no-op.
            guard case .frame(_, let isMainFrame, _) = sender, isMainFrame, let senderWebView,
                  let panel = panels.panels.first(where: { $0.webView === senderWebView }) else {
                replyHandler(false, nil)
                return
            }
            panels.close(panel, reason: .pageClosedItself)
            replyHandler(true, nil)
            return
        }

        var tab: BrowserTab?
        if let handle = params["tabHandle"], !(handle is NSNull) {
            switch resolveTabHandle(handle) {
            case .failure(let error):
                replyHandler(nil, Self.tabHandleRefusal(error, type: type))
                return
            case .success(let resolved):
                tab = resolved.tab
            }
        }

        switch type {
        case "sidePanel.setOptions":
            switch panels.setOptions(extensionID: extensionID, tab: tab,
                                     path: params["path"] as? String, enabled: Self.boolean(params["enabled"])) {
            case .success: replyHandler(true, nil)
            case .failure(let error): replyHandler(nil, error.message)
            }

        case "sidePanel.getOptions":
            let (options, isTabSpecific) = panels.options(extensionID: extensionID, tab: tab)
            var reply: [String: Any] = ["enabled": options.enabled, "tabSpecific": isTabSpecific]
            if let path = options.path { reply["path"] = path }
            replyHandler(reply, nil)

        case "sidePanel.open", "sidePanel.close":
            let window: BrowserWindowController?
            switch sidePanelWindow(params: params, type: type, senderWebView: senderWebView) {
            case .failure(let error):
                replyHandler(nil, error.message)
                return
            case .success(let resolved):
                window = resolved
            }
            if type == "sidePanel.close" {
                guard tab != nil || window != nil else {
                    replyHandler(nil, "At least one of \"tabId\" and \"windowId\" must be provided")
                    return
                }
                panels.close(extensionID: extensionID, tab: tab, window: window)
                replyHandler(true, nil)
                return
            }
            switch panels.openFromExtension(extensionID: extensionID, tab: tab, window: window) {
            case .success: replyHandler(true, nil)
            case .failure(let error): replyHandler(nil, error.message)
            }

        case "sidePanel.setPanelBehavior":
            if let opens = Self.boolean(params["openPanelOnActionClick"]) {
                panels.setOpensPanelOnActionClick(opens, extensionID: extensionID)
            }
            replyHandler(true, nil)

        case "sidePanel.getPanelBehavior":
            replyHandler(["openPanelOnActionClick": panels.opensPanelOnActionClick(extensionID: extensionID)], nil)

        default:
            replyHandler(nil, "Unknown polyfill message type: \(type)")
        }
    }

    /// A JS boolean, and nothing else: a number would also convert.
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// The browser window a call's `windowId` means, or nil when the call
    /// named none.
    ///
    /// WebKit mints the window ids and offers no lookup from one, and there is
    /// no window bridge yet, so the polyfill sends what it can learn from
    /// `windows.get(windowId, { populate: true })`: the handle of the window's
    /// active tab (`windowTabHandle`). The window is then the one showing that
    /// tab's live web view, else the one WebKit is told the tab is in.
    ///
    /// A window with no tab cannot be named that way (`hasWindow` without a
    /// handle). The call then means, in this order: the window the calling
    /// page is in (a tab's, a popup's, a panel's — the worker has none), the
    /// key window when it shows this profile, the first window that does.
    private func sidePanelWindow(params: [String: Any], type: String,
                                 senderWebView: WKWebView?) -> Result<BrowserWindowController?, ExtensionSidePanelController.APIError> {
        if let handle = params["windowTabHandle"], !(handle is NSNull) {
            switch resolveTabHandle(handle) {
            case .failure(let error):
                return .failure(.init(message: Self.tabHandleRefusal(error, type: type)))
            case .success(let resolved):
                guard let window = ExtensionSidePanelController.window(showing: resolved.tab) else {
                    return .failure(.init(message: "\(type): the window is not open"))
                }
                return .success(window)
            }
        }
        guard Self.boolean(params["hasWindow"]) == true else { return .success(nil) }
        if let window = Self.browserWindow(containing: senderWebView), window.activeSpace?.profileID == profile?.id {
            return .success(window)
        }
        guard let window = profile?.sidePanels.fallbackWindow() else {
            return .failure(.init(message: "\(type): the window is not open"))
        }
        return .success(window)
    }

    /// The browser window a web view is in: its own, or — for a popup in a
    /// popover — the window the popover is attached to.
    static func browserWindow(containing webView: WKWebView?) -> BrowserWindowController? {
        var window = webView?.window
        while let current = window {
            if let controller = current.windowController as? BrowserWindowController { return controller }
            window = current.parent
        }
        return nil
    }
}
