import Foundation

// The rules of `chrome.sidePanel` for one extension in one profile (TASK-132.8):
// which page a panel shows, whether it may open, and which panels are open.
// Pure — no web views, no windows — so every rule can be unit-tested; the
// objects behind the keys live in `ExtensionSidePanelController`.

/// What an extension set with `sidePanel.setOptions` for one tab, or as its
/// default. A nil field was never set.
struct ExtensionSidePanelOptions: Equatable {
    var path: String?
    var enabled: Bool?

    var isEmpty: Bool { path == nil && enabled == nil }
}

/// The options in force for a tab (or, with no tab, for the default panel):
/// each field the tab did not set comes from the default, and the default's
/// own path from the manifest's `side_panel.default_path`.
struct ExtensionSidePanelResolvedOptions: Equatable {
    let path: String?
    let enabled: Bool

    /// A panel can be opened: it is enabled and there is a page to show.
    var isOpenable: Bool { enabled && path != nil }
}

/// Where an open panel belongs. A *tab* panel shows only with its tab; a
/// *window* panel shows beside every tab of its window that has no open tab
/// panel of its own.
enum ExtensionSidePanelScope<Tab: Hashable, Window: Hashable>: Hashable {
    case tab(Tab)
    case window(Window)
}

/// Why `sidePanel.open` was refused.
enum ExtensionSidePanelOpenError: Error, Equatable {
    /// Neither a tab nor a window was named.
    case missingTarget
    /// The tab's options (its own, or the default) are disabled or have no path.
    case noActivePanelForTab
    /// The default options are disabled or have no path.
    case noActivePanelForWindow
    /// The tab has no panel of its own and no window to show the default one in.
    case noWindowForTab
}

struct ExtensionSidePanelState<Tab: Hashable, Window: Hashable> {
    typealias Scope = ExtensionSidePanelScope<Tab, Window>

    /// The manifest's `side_panel.default_path`, the default panel until
    /// `setOptions` names another.
    let manifestDefaultPath: String?

    private(set) var defaultOptions = ExtensionSidePanelOptions()
    private(set) var tabOptions: [Tab: ExtensionSidePanelOptions] = [:]
    /// `sidePanel.setPanelBehavior({ openPanelOnActionClick })`.
    var openPanelOnActionClick = false
    /// The open panels, oldest first.
    private(set) var openScopes: [Scope] = []

    init(manifestDefaultPath: String? = nil) {
        self.manifestDefaultPath = manifestDefaultPath.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Options

    /// `sidePanel.setOptions`: only the fields given change. With a tab, the
    /// tab gets options of its own — which is what makes its panel a tab panel.
    mutating func setOptions(tab: Tab?, path: String?, enabled: Bool?) {
        if let tab {
            var options = tabOptions[tab] ?? ExtensionSidePanelOptions()
            if let path { options.path = path }
            if let enabled { options.enabled = enabled }
            tabOptions[tab] = options
        } else {
            if let path { defaultOptions.path = path }
            if let enabled { defaultOptions.enabled = enabled }
        }
    }

    /// Whether `setOptions` was called for this tab.
    func hasOptions(for tab: Tab) -> Bool {
        tabOptions[tab] != nil
    }

    /// The options in force for `tab`, or the default ones with no tab.
    func resolvedOptions(for tab: Tab?) -> ExtensionSidePanelResolvedOptions {
        let defaultPath = defaultOptions.path ?? manifestDefaultPath
        let defaultEnabled = defaultOptions.enabled ?? true
        guard let tab, let own = tabOptions[tab] else {
            return ExtensionSidePanelResolvedOptions(path: defaultPath, enabled: defaultEnabled)
        }
        return ExtensionSidePanelResolvedOptions(path: own.path ?? defaultPath, enabled: own.enabled ?? defaultEnabled)
    }

    /// The options a panel of `scope` shows with.
    func resolvedOptions(for scope: Scope) -> ExtensionSidePanelResolvedOptions {
        switch scope {
        case .tab(let tab): return resolvedOptions(for: tab)
        case .window: return resolvedOptions(for: nil)
        }
    }

    // MARK: Open panels

    func isOpen(_ scope: Scope) -> Bool {
        openScopes.contains(scope)
    }

    /// `sidePanel.open`. A tab that has options of its own opens its tab panel;
    /// any other tab opens the default panel in `window` (the tab's window).
    /// With no tab, the default panel opens in `window`. Opening an open panel
    /// changes nothing but its place in `openScopes` (most recent last).
    mutating func open(tab: Tab?, window: Window?) -> Result<Scope, ExtensionSidePanelOpenError> {
        let scope: Scope
        if let tab {
            guard resolvedOptions(for: tab).isOpenable else { return .failure(.noActivePanelForTab) }
            if hasOptions(for: tab) {
                scope = .tab(tab)
            } else if let window {
                scope = .window(window)
            } else {
                return .failure(.noWindowForTab)
            }
        } else if let window {
            guard resolvedOptions(for: nil).isOpenable else { return .failure(.noActivePanelForWindow) }
            scope = .window(window)
        } else {
            return .failure(.missingTarget)
        }
        openScopes.removeAll { $0 == scope }
        openScopes.append(scope)
        return .success(scope)
    }

    /// `sidePanel.close`: the tab's own panel when it is open, otherwise the
    /// default panel of `window`. Returns what was closed; closing a closed
    /// panel is not an error.
    @discardableResult
    mutating func close(tab: Tab?, window: Window?) -> [Scope] {
        var closed: [Scope] = []
        if let tab, isOpen(.tab(tab)) {
            closed.append(.tab(tab))
        } else if let window, isOpen(.window(window)) {
            closed.append(.window(window))
        }
        openScopes.removeAll { closed.contains($0) }
        return closed
    }

    /// One panel went away by itself (the user closed it, its page called
    /// `window.close()`, its load failed).
    mutating func didClose(_ scope: Scope) {
        openScopes.removeAll { $0 == scope }
    }

    /// The open panels that may no longer be open after an options change:
    /// their options are now disabled or have no path. They are removed from
    /// `openScopes` and returned.
    mutating func closeScopesNoLongerOpenable() -> [Scope] {
        let stale = openScopes.filter { !resolvedOptions(for: $0).isOpenable }
        openScopes.removeAll { stale.contains($0) }
        return stale
    }

    /// The tab is gone: its options and its panel go with it. Returns the
    /// panel's scope when one was open.
    @discardableResult
    mutating func forget(tab: Tab) -> Scope? {
        tabOptions[tab] = nil
        guard isOpen(.tab(tab)) else { return nil }
        openScopes.removeAll { $0 == .tab(tab) }
        return .tab(tab)
    }

    /// The window is gone. Returns its panel's scope when one was open.
    @discardableResult
    mutating func forget(window: Window) -> Scope? {
        guard isOpen(.window(window)) else { return nil }
        openScopes.removeAll { $0 == .window(window) }
        return .window(window)
    }

    /// Every panel is closed (the context is unloading). Options and the
    /// behaviour are kept only as long as the state itself is.
    mutating func closeAll() -> [Scope] {
        defer { openScopes.removeAll() }
        return openScopes
    }
}

// MARK: - Which panel a window shows

/// One open panel, as far as choosing between panels is concerned.
struct ExtensionSidePanelCandidate<Tab: Hashable, Window: Hashable, ID: Hashable>: Equatable {
    let id: ID
    let scope: ExtensionSidePanelScope<Tab, Window>
    /// When it was opened, or last asked to open: the larger, the more recent.
    let recency: Int
}

/// The panel a window shows, or nil for none.
///
/// - `displayedTabs`: the tabs whose live web views the window is showing —
///   the focused pane first, then the other pane of a split. Empty when the
///   window shows a snapshot (another window owns the tab's web view) or
///   nothing at all, so a tab panel only ever shows beside the live page.
/// - An open tab panel of a displayed tab wins over the window's own panel;
///   between two (the panes of a split each have one), the focused pane's.
/// - Otherwise the window's own panel. Two extensions can each have a panel in
///   the same place: the most recently opened one shows.
/// - `isDisabledForTab`: whether the extension behind a panel disabled its
///   panel for a tab (`setOptions({tabId, enabled: false})`). A window panel
///   stays open but is hidden beside the focused tab it is disabled for, as in
///   Chrome; it shows again with the next tab.
func sidePanelToDisplay<Tab: Hashable, Window: Hashable, ID: Hashable>(
    window: Window,
    displayedTabs: [Tab],
    candidates: [ExtensionSidePanelCandidate<Tab, Window, ID>],
    isDisabledForTab: (ID, Tab) -> Bool = { _, _ in false }
) -> ID? {
    for tab in displayedTabs {
        let forTab = candidates.filter { $0.scope == .tab(tab) }
        if let latest = forTab.max(by: { $0.recency < $1.recency }) { return latest.id }
    }
    let forWindow = candidates.filter { candidate in
        guard candidate.scope == .window(window) else { return false }
        return displayedTabs.first.map { !isDisabledForTab(candidate.id, $0) } ?? true
    }
    return forWindow.max(by: { $0.recency < $1.recency })?.id
}

// MARK: - Layout

/// Where the tab content and a side panel sit in the window's content area.
/// The panel keeps its width when the window resizes, down to
/// `minimumPanelWidth`; the content keeps at least `minimumContentWidth` as
/// long as the panel can still have its minimum.
enum SidePanelLayout {
    static let minimumPanelWidth: CGFloat = 280
    static let minimumContentWidth: CGFloat = 240
    static let defaultPanelWidth: CGFloat = 380
    /// The draggable strip between content and panel. It lies over the
    /// panel's leading edge and takes no width of its own.
    static let dividerHitWidth: CGFloat = 7

    struct Frames: Equatable {
        let content: CGRect
        let panel: CGRect
        /// The strip that takes the resize drag, centred on the boundary.
        let divider: CGRect
    }

    /// The panel width actually used for a wanted width in a content area
    /// `totalWidth` wide.
    static func clampedPanelWidth(_ wanted: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let maximum = max(minimumPanelWidth, totalWidth - minimumContentWidth)
        let clamped = min(max(wanted, minimumPanelWidth), maximum)
        // A content area narrower than the panel's minimum: the panel takes it all.
        return min(clamped, max(totalWidth, 0))
    }

    /// The frames for a panel `wantedPanelWidth` wide at the trailing edge of
    /// `bounds`. With no panel the content fills `bounds`.
    static func frames(in bounds: CGRect, wantedPanelWidth: CGFloat?) -> Frames {
        guard let wantedPanelWidth else {
            return Frames(content: bounds, panel: .zero, divider: .zero)
        }
        let panelWidth = clampedPanelWidth(wantedPanelWidth, totalWidth: bounds.width).rounded()
        let boundary = bounds.maxX - panelWidth
        return Frames(
            content: CGRect(x: bounds.minX, y: bounds.minY, width: max(boundary - bounds.minX, 0), height: bounds.height),
            panel: CGRect(x: boundary, y: bounds.minY, width: panelWidth, height: bounds.height),
            divider: CGRect(x: boundary - dividerHitWidth / 2, y: bounds.minY,
                            width: dividerHitWidth, height: bounds.height))
    }

    /// The wanted panel width after the divider was dragged to `boundaryX`.
    static func panelWidth(forBoundaryAt boundaryX: CGFloat, in bounds: CGRect) -> CGFloat {
        clampedPanelWidth(bounds.maxX - boundaryX, totalWidth: bounds.width)
    }
}
