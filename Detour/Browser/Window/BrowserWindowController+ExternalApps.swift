import AppKit
import WebKit

// MARK: - External application URLs (TASK-84)

extension BrowserWindowController {

    /// Opens `url` in the application registered for its scheme, asking first
    /// unless the requesting origin was "Always allowed" for that scheme in the
    /// navigating tab's profile. The rule is `ExternalAppLaunchPolicy`.
    ///
    /// The sheet is begun synchronously, inside the policy decision, so a page
    /// firing the same request again in a tight loop sees `attachedSheet` and is
    /// dropped instead of queueing prompts.
    func handleExternalAppNavigation(to url: URL, action: WKNavigationAction, in webView: WKWebView) {
        guard let scheme = url.scheme?.lowercased() else { return }
        let appURL = NSWorkspace.shared.urlForApplication(toOpen: url)
        let profile = tab(owning: webView)?.owningProfile ?? activeSpace?.profile
        let origin = Self.requestingOrigin(of: action)
        let store = ExternalAppPermissionStore.shared
        var isAllowed = false
        if let origin, let profile {
            isAllowed = store.isAllowed(origin: origin, scheme: scheme, profileID: profile.id)
        }

        let decision = ExternalAppLaunchPolicy.decide(
            hasHandler: appURL != nil,
            isAllowed: isAllowed,
            isHostedInWindow: window != nil && isHostedInWindow(webView),
            isMainFrameRequest: action.targetFrame?.isMainFrame ?? true,
            isSheetShowing: window?.attachedSheet != nil,
            origin: origin,
            isPrivateProfile: profile?.isIncognito ?? true)

        switch decision {
        case .open:
            NSWorkspace.shared.open(url)
        case .reportNoHandler:
            toastManager.show(message: "No application can open “\(scheme):” links")
        case .ignore:
            break
        case .prompt(let canRemember):
            guard let window, let appURL else { return }
            let appName = FileManager.default.displayName(atPath: appURL.path)
            let alert = NSAlert()
            alert.messageText = "Open “\(appName)”?"
            alert.informativeText = origin.map { "\($0) wants to open this application." }
                ?? "This page wants to open this application."
            alert.icon = NSWorkspace.shared.icon(forFile: appURL.path)
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            if canRemember, let origin {
                alert.showsSuppressionButton = true
                let site = URL(string: origin)?.host ?? origin
                alert.suppressionButton?.title = "Always allow \(site) to open links of this type in \(appName)"
            }
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                if canRemember, alert.suppressionButton?.state == .on, let origin, let profile {
                    store.allow(origin: origin, scheme: scheme, profileID: profile.id,
                                isPrivateProfile: profile.isIncognito)
                    NotificationCenter.default.post(name: ExternalAppPermissionStore.didChangeNotification,
                                                    object: store)
                }
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Whether `webView` is on screen in this window: the selected tab, a pane
    /// of its split, or the selected tab's peek.
    private func isHostedInWindow(_ webView: WKWebView) -> Bool {
        guard let selected = selectedTab else { return false }
        if selected.webView === webView || selected.peekTab?.webView === webView { return true }
        return splitMembers(of: selected).contains { $0.webView === webView }
    }

    /// The origin key of the frame that asked for the navigation. Read through
    /// KVC because `sourceFrame` is imported as non-optional yet is nil for
    /// navigations the app itself started (`load(_:)`), and a nil read through
    /// the typed accessor is undefined behaviour.
    private static func requestingOrigin(of action: WKNavigationAction) -> String? {
        guard let frame = action.value(forKey: "sourceFrame") as? WKFrameInfo else { return nil }
        let origin = frame.securityOrigin
        return ExternalAppLaunchPolicy.origin(protocol: origin.protocol, host: origin.host, port: origin.port)
    }
}
