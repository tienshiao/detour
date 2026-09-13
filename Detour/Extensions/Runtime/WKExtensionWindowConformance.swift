import AppKit
import WebKit

// MARK: - BrowserWindowController + WKWebExtensionWindow

extension BrowserWindowController: WKWebExtensionWindow {
    /// The tabs this window reports to extensions — see `extensionWindowTabs`:
    /// pinned, normal, then the live favourite backing tabs of the profile the
    /// window is showing, each followed by its live Peek (TASK-50). Also the
    /// membership test `BrowserTab.window(for:)` uses, so the two never disagree.
    var extensionTabs: [BrowserTab] {
        guard let space = activeSpace else { return [] }
        return extensionWindowTabs(pinned: space.pinnedTabs, normal: space.tabs,
                                   favorites: space.profile?.favoriteTabs ?? [])
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        extensionTabs
    }

    /// The presented Peek while one is up, otherwise the selected tab
    /// (TASK-51) — `tabs.query({active: true})` must never name a page hidden
    /// behind the overlay.
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        extensionActiveTab
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
