import AppKit
import WebKit

// MARK: - BrowserWindowController + WKWebExtensionWindow

extension BrowserWindowController: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        return (activeSpace?.pinnedTabs ?? []) + currentTabs
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        selectedTab
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        isIncognito
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        window?.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        window?.screen?.frame ?? .null
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let w = window else { return .normal }
        if w.styleMask.contains(.fullScreen) { return .fullscreen }
        if w.isMiniaturized { return .minimized }
        if w.isZoomed { return .maximized }
        return .normal
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.close()
        completionHandler(nil)
    }
}
