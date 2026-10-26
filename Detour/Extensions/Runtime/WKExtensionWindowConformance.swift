import AppKit
import WebKit

/// A window the extension contexts are told about: a browser window, or a
/// Quick Detour window (TASK-193.1). What every enumeration of windows —
/// `openWindowsFor`, `focusedWindowFor`, `BrowserTab.window(for:)`, a context
/// loading — goes through, so the two kinds are never listed differently.
protocol ExtensionListedWindow: WKWebExtensionWindow {
    /// The tabs the window reports, in order (`tabs(for:)`).
    var extensionTabs: [BrowserTab] { get }
    /// The tab the window reports as active (`activeTab(for:)`).
    var extensionActiveTab: BrowserTab? { get }
    /// The profile whose contexts see this window; nil for none (a window
    /// with no space yet). A window is listed only to its profile's contexts.
    var extensionProfileID: UUID? { get }
    var window: NSWindow? { get }
}

/// Every window the extension contexts may be told about, front to back: the
/// browser windows and the Quick Detour windows in `NSApp.windows` order, then
/// any open Quick Detour whose window AppKit does not list yet (one being
/// built: its tab is reported open before it is ordered in).
func extensionListedWindows() -> [any ExtensionListedWindow] {
    var listed: [any ExtensionListedWindow] = NSApp.windows.compactMap {
        $0.windowController as? (any ExtensionListedWindow)
    }
    for quick in QuickDetourWindowController.openControllers where !listed.contains(where: { $0 === quick }) {
        listed.append(quick)
    }
    return listed
}

// MARK: - BrowserWindowController + WKWebExtensionWindow

extension BrowserWindowController: ExtensionListedWindow {
    var extensionProfileID: UUID? { activeSpace?.profileID }

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
