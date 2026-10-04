import AppKit
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "ext-sidepanel")

// TASK-132.8: `chrome.sidePanel`, hosted by Detour.
//
// Released WebKit compiles its side panel out (TASK-132.1), so the API is a
// polyfill module (`ExtensionAPIPolyfill.sidePanelJS`) and the panel is a web
// view Detour builds from the extension context's configuration — the way the
// offscreen document is built — which gives it the extension's `chrome.*`, the
// polyfill and the profile's data store.
//
// A panel is not a tab. It has no `BrowserTab`, no sidebar row, is never
// `selectedTabID`, and WebKit is told nothing about it, so `tabs.query`, the
// Control+Tab switcher and the closed-tab records cannot contain it and
// `tabs.getCurrent()` in its page answers undefined.
//
// The pieces:
//   - `ExtensionSidePanelState`      — the rules (pure, in its own file).
//   - `ExtensionSidePanelController` — one per profile: the state of every
//     extension in it, the open panels, and the entry points the polyfill
//     handler and Detour's own UI call.
//   - `ExtensionSidePanel`           — one open panel: its web view, kept alive
//     for as long as the panel is open whether or not a window shows it.
//   - `ExtensionSidePanelView`       — what a window puts beside the tab.
//   - `BrowserWindowController+SidePanel` — which panel a window shows.

// MARK: - The panel's view

/// A panel as a window shows it: a header (the extension's icon and name, a
/// close button) over the panel's web view. Frames and autoresizing masks
/// only, so the panel's own Web Inspector can dock.
final class ExtensionSidePanelView: NSView {
    static let headerHeight: CGFloat = 38

    weak var panel: ExtensionSidePanel?

    private let header = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    let closeButton = HoverButton()
    private let headerSeparator = NSBox()
    /// Holds the web view and whatever WebKit docks beside it.
    let webViewHolder = NSView()

    init(title: String, icon: NSImage?) {
        // A real size to start from: autoresizing masks scale from it.
        super.init(frame: NSRect(x: 0, y: 0, width: SidePanelLayout.defaultPanelWidth, height: 600))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title) side panel")

        let height = Self.headerHeight
        header.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        header.autoresizingMask = [.width, .minYMargin]
        addSubview(header)

        iconView.image = icon ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: 12, y: (height - 16) / 2, width: 16, height: 16)
        iconView.autoresizingMask = [.maxXMargin]
        header.addSubview(iconView)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close side panel")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.circular = true
        closeButton.fixedHoverSize = 22
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close \(title)"
        closeButton.setAccessibilityLabel("Close \(title) side panel")
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.frame = NSRect(x: bounds.width - 8 - 24, y: (height - 24) / 2, width: 24, height: 24)
        closeButton.autoresizingMask = [.minXMargin]
        header.addSubview(closeButton)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        let labelX: CGFloat = 12 + 16 + 8
        titleLabel.frame = NSRect(x: labelX, y: (height - 16) / 2, width: closeButton.frame.minX - 8 - labelX, height: 16)
        titleLabel.autoresizingMask = [.width]
        header.addSubview(titleLabel)

        headerSeparator.boxType = .separator
        headerSeparator.frame = NSRect(x: 0, y: bounds.height - height - 1, width: bounds.width, height: 1)
        headerSeparator.autoresizingMask = [.width, .minYMargin]
        addSubview(headerSeparator)

        webViewHolder.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - height - 1)
        webViewHolder.autoresizingMask = [.width, .height]
        addSubview(webViewHolder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    func host(_ webView: WKWebView) {
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.frame = webViewHolder.bounds
        webViewHolder.addSubview(webView)
    }

    @objc private func closeClicked(_ sender: Any?) {
        panel?.closeFromUserInterface()
    }
}

// MARK: - One open panel

/// `-[WKWebView _setShouldSuppressFirstResponderChanges:]`, declared in
/// WebKit's `WKWebViewPrivate.h` (macOS 10.13.4+): the web view no longer makes
/// itself first responder when its web process asks. There is no public
/// equivalent.
@objc protocol WKWebViewFirstResponderShim {
    @objc(_setShouldSuppressFirstResponderChanges:)
    func setShouldSuppressFirstResponderChanges(_ suppress: Bool)
}

/// A side panel's web view. Its page cannot make it first responder
/// (`ExtensionSidePanel.suppressFirstResponderChanges`) — and a mouse press in
/// a page asks for the keys the same way (see `BrowserWindow`), so it would be
/// suppressed with the rest. The press therefore hands the keys over here,
/// where it is plainly the user's doing.
final class ExtensionSidePanelWebView: WKWebView {
    override func mouseDown(with event: NSEvent) {
        takeKeys()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        takeKeys()
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        takeKeys()
        super.otherMouseDown(with: event)
    }

    private func takeKeys() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }
}

/// Why a panel closed — for the log.
enum ExtensionSidePanelCloseReason: String {
    case api = "sidePanel.close"
    case options = "its options were disabled or lost their path"
    case user = "the user closed it"
    case pageClosedItself = "its page called window.close()"
    case tabClosed = "its tab closed"
    case windowClosed = "its window closed"
    case contextUnloaded = "the extension was unloaded"
    case loadFailed = "its page failed to load"
    case replaced = "another panel was opened in its place"
}

/// One open side panel. Its web view lives from `open` to `close`, on screen or
/// not: a panel hidden with its tab is detached from the window, never
/// reloaded.
final class ExtensionSidePanel: NSObject, WKNavigationDelegate, WKUIDelegate {
    typealias Scope = ExtensionSidePanelScope<UUID, ObjectIdentifier>

    let extensionID: String
    let scope: Scope
    /// The tab a tab panel shows with.
    private(set) weak var tab: BrowserTab?
    /// The window a window panel belongs to.
    private(set) weak var windowController: BrowserWindowController?
    private(set) weak var controller: ExtensionSidePanelController?
    private(set) var webView: WKWebView?
    let view: ExtensionSidePanelView
    /// The page the options name. Compared with a later `setOptions` to decide
    /// whether the panel has to load another page.
    private(set) var requestedURL: URL
    /// The larger, the more recently opened (or asked to open again).
    var recency: Int
    /// True until the requested page has committed: a failure before that
    /// closes the panel, one after it is the page's own navigation.
    private var isLoadingRequestedURL = true
    /// Set while the panel's tab was found in no list and a second look is
    /// queued (`ExtensionSidePanelController.closeIfStillUnlisted`).
    fileprivate var awaitsPlacementCheck = false

    init(extensionID: String, scope: Scope, tab: BrowserTab?, windowController: BrowserWindowController?,
         controller: ExtensionSidePanelController, configuration: WKWebViewConfiguration, url: URL,
         title: String, icon: NSImage?, recency: Int) {
        self.extensionID = extensionID
        self.scope = scope
        self.tab = tab
        self.windowController = windowController
        self.controller = controller
        self.requestedURL = url
        self.recency = recency
        self.view = ExtensionSidePanelView(title: title, icon: icon)
        super.init()

        let webView = ExtensionSidePanelWebView(frame: view.webViewHolder.bounds, configuration: configuration)
        // Detour built this view, so it is never the extension's background
        // page, whatever its page navigates to (TASK-66).
        ExtensionPageHostRegistry.register(webView)
        // Who has the keys is Detour's decision (`open(focus:)`), not the
        // page's: see `suppressFirstResponderChanges`.
        Self.suppressFirstResponderChanges(of: webView)
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView
        view.panel = self
        view.host(webView)
        webView.load(URLRequest(url: url))
    }

    /// Stops the page from taking keyboard focus for its web view.
    ///
    /// WebKit makes a web view first responder whenever its page focuses an
    /// element — an `autofocus` field, a script's `focus()` — by a message
    /// from the web process (`WebPageProxy::makeFirstResponder`, measured:
    /// it arrives once the page has loaded). A panel whose page does that
    /// would take the keys from the tab on every `sidePanel.open`, user
    /// gesture or not. With the changes suppressed the panel has the keys
    /// only when Detour hands them over (`open(focus:)`) or the user clicks in
    /// it (`ExtensionSidePanelWebView`).
    static func suppressFirstResponderChanges(of webView: WKWebView) {
        let selector = NSSelectorFromString("_setShouldSuppressFirstResponderChanges:")
        guard webView.responds(to: selector) else {
            if !reportedMissingFirstResponderSPI {
                reportedMissingFirstResponderSPI = true
                log.error("WKWebView does not respond to _setShouldSuppressFirstResponderChanges: — a side panel whose page focuses a field takes keyboard focus when it loads")
            }
            return
        }
        unsafeBitCast(webView, to: WKWebViewFirstResponderShim.self).setShouldSuppressFirstResponderChanges(true)
    }

    private static var reportedMissingFirstResponderSPI = false

    /// The page the panel is on, query included.
    var documentURL: URL { webView?.url ?? requestedURL }

    /// The browser window showing the panel right now, if any.
    var hostingWindow: BrowserWindowController? {
        view.window?.windowController as? BrowserWindowController
    }

    /// `setOptions` named another page for an open panel.
    func load(_ url: URL) {
        guard url != requestedURL else { return }
        requestedURL = url
        isLoadingRequestedURL = true
        webView?.load(URLRequest(url: url))
    }

    func closeFromUserInterface() {
        controller?.close(self, reason: .user)
    }

    /// Releases the web view. The page goes away with it, which is what the
    /// extension sees: its ports disconnect and the context is gone from
    /// `runtime.getContexts`.
    fileprivate func teardown() {
        view.removeFromSuperview()
        guard let webView else { return }
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        self.webView = nil
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        isLoadingRequestedURL = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failLoad(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failLoad(error)
    }

    private func failLoad(_ error: any Error) {
        guard !error.isSupersededNavigationError, isLoadingRequestedURL else { return }
        log.error("The side panel of \(self.extensionID, privacy: .public) failed to load: \(error.localizedDescription, privacy: .public)")
        controller?.close(self, reason: .loadFailed)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.notice("The side panel of \(self.extensionID, privacy: .public) lost its web content process; loading it again")
        isLoadingRequestedURL = true
        webView.load(URLRequest(url: requestedURL))
    }

    // MARK: WKUIDelegate

    /// `window.close()` in the panel's page closes the panel, as in Chrome.
    func webViewDidClose(_ webView: WKWebView) {
        controller?.close(self, reason: .pageClosedItself)
    }

    /// A link or `window.open` from the panel opens a tab beside it: a panel
    /// has no windows of its own.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url, !InternalPage.isInternal(url),
              let window = hostingWindow ?? controller?.fallbackWindow(), let space = window.activeSpace else { return nil }
        let tab = TabStore.shared.addTab(in: space, url: url)
        window.selectTab(id: tab.id)
        return nil
    }
}

// MARK: - The controller

/// `chrome.sidePanel` for one profile: every loaded extension's options and
/// behaviour, and the panels that are open. One per `Profile`, so nothing here
/// can reach another profile's panels or tabs.
///
/// Main thread only, like the polyfill handler and the windows it serves.
final class ExtensionSidePanelController {
    typealias State = ExtensionSidePanelState<UUID, ObjectIdentifier>
    typealias Scope = ExtensionSidePanelScope<UUID, ObjectIdentifier>

    /// A failed API call, as the text the extension is given.
    struct APIError: Error, Equatable {
        let message: String
    }

    private static let controllers = NSHashTable<ExtensionSidePanelController>.weakObjects()
    private static var recencyCounter = 0
    private static var isReconciling = false
    private static var reconcileAgain = false

    /// Every open panel, in every profile.
    static var allPanels: [ExtensionSidePanel] {
        controllers.allObjects.flatMap(\.panels)
    }

    private(set) weak var profile: Profile?
    private var states: [String: State] = [:]
    private(set) var panels: [ExtensionSidePanel] = []

    /// How long after the user clicked an extension's toolbar action or pressed
    /// one of its command shortcuts a `sidePanel.open` still counts as the
    /// user's own doing, and may take keyboard focus.
    static let userGestureLifetime: TimeInterval = 5
    private var userGestures: [String: TimeInterval] = [:]
    /// Monotonic seconds; tests inject their own.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    init(profile: Profile) {
        self.profile = profile
        Self.controllers.add(self)
    }

    // MARK: State

    private func state(for extensionID: String) -> State {
        if let state = states[extensionID] { return state }
        let manifestPath = ExtensionManager.shared.extension(withID: extensionID)?.manifest.sidePanel?.defaultPath
        return State(manifestDefaultPath: manifestPath)
    }

    /// The state, for tests.
    func stateForTesting(extensionID: String) -> State { state(for: extensionID) }

    func panels(for extensionID: String) -> [ExtensionSidePanel] {
        panels.filter { $0.extensionID == extensionID }
    }

    private func panel(extensionID: String, scope: Scope) -> ExtensionSidePanel? {
        panels.first { $0.extensionID == extensionID && $0.scope == scope }
    }

    /// The page a path names, or nil when it is not a page of the extension's
    /// own package: only those may be a side panel.
    static func panelURL(path: String, baseURL: URL) -> URL? {
        guard !path.isEmpty, let host = baseURL.host,
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              isExtensionPage(url, ofOriginHost: host) else { return nil }
        return url
    }

    // MARK: User gestures

    /// The user just clicked the extension's toolbar action or pressed one of
    /// its command shortcuts.
    func noteUserGesture(extensionID: String) {
        userGestures[extensionID] = clock()
    }

    /// Whether a gesture was noted for the extension a moment ago. One gesture
    /// lets one panel take focus.
    private func consumeUserGesture(extensionID: String) -> Bool {
        guard let at = userGestures.removeValue(forKey: extensionID) else { return false }
        return clock() - at <= Self.userGestureLifetime
    }

    // MARK: sidePanel.setOptions / getOptions

    func setOptions(extensionID: String, tab: BrowserTab?, path: String?, enabled: Bool?) -> Result<Void, APIError> {
        guard let context = profile?.extensionContext(for: extensionID) else {
            return .failure(APIError(message: "sidePanel.setOptions: the extension is not loaded in this profile"))
        }
        if let path, Self.panelURL(path: path, baseURL: context.baseURL) == nil {
            return .failure(APIError(message: "sidePanel.setOptions: the path must be a page in the extension's own package"))
        }
        var state = state(for: extensionID)
        state.setOptions(tab: tab?.id, path: path, enabled: enabled)
        let stale = state.closeScopesNoLongerOpenable()
        states[extensionID] = state

        for scope in stale {
            if let panel = panel(extensionID: extensionID, scope: scope) { remove(panel, reason: .options) }
        }
        // An open panel whose page the options no longer name loads the new one.
        for panel in panels(for: extensionID) {
            if let path = state.resolvedOptions(for: panel.scope).path,
               let url = Self.panelURL(path: path, baseURL: context.baseURL) {
                panel.load(url)
            }
        }
        Self.reconcile()
        return .success(())
    }

    /// The options in force for `tab` (the default ones with no tab), and
    /// whether the tab has options of its own.
    func options(extensionID: String, tab: BrowserTab?) -> (options: ExtensionSidePanelResolvedOptions, isTabSpecific: Bool) {
        let state = state(for: extensionID)
        return (state.resolvedOptions(for: tab?.id), tab.map { state.hasOptions(for: $0.id) } ?? false)
    }

    // MARK: sidePanel.setPanelBehavior / getPanelBehavior

    func opensPanelOnActionClick(extensionID: String) -> Bool {
        state(for: extensionID).openPanelOnActionClick
    }

    func setOpensPanelOnActionClick(_ opens: Bool, extensionID: String) {
        var state = state(for: extensionID)
        state.openPanelOnActionClick = opens
        states[extensionID] = state
    }

    // MARK: sidePanel.open / close

    /// Opens the extension's panel for `tab` — its own panel when the tab has
    /// options of its own, else the default panel in the tab's window — or,
    /// with no tab, the default panel in `window`.
    ///
    /// `focus` is whether the panel takes keyboard focus once a window shows
    /// it: true when Detour opens it on a click, and for the API call only
    /// when the user clicked the extension's action or pressed its shortcut a
    /// moment ago (`noteUserGesture`).
    @discardableResult
    func open(extensionID: String, tab: BrowserTab?, window: BrowserWindowController?,
              focus: Bool) -> Result<ExtensionSidePanel, APIError> {
        guard let profile, let context = profile.extensionContext(for: extensionID) else {
            return .failure(APIError(message: "sidePanel.open: the extension is not loaded in this profile"))
        }
        let targetWindow = window ?? tab.flatMap(Self.window(showing:))
        var state = state(for: extensionID)
        let scope: Scope
        switch state.open(tab: tab?.id, window: targetWindow.map(ObjectIdentifier.init)) {
        case .success(let opened):
            scope = opened
        case .failure(let error):
            return .failure(APIError(message: Self.message(for: error)))
        }
        guard let path = state.resolvedOptions(for: scope).path,
              let url = Self.panelURL(path: path, baseURL: context.baseURL),
              let configuration = context.webViewConfiguration else {
            return .failure(APIError(message: "sidePanel.open: the panel's page cannot be loaded"))
        }
        states[extensionID] = state

        Self.recencyCounter += 1
        let panel: ExtensionSidePanel
        if let existing = self.panel(extensionID: extensionID, scope: scope) {
            existing.recency = Self.recencyCounter
            existing.load(url)
            panel = existing
        } else {
            let ext = ExtensionManager.shared.extension(withID: extensionID)
            let isTabScope: Bool
            if case .tab = scope { isTabScope = true } else { isTabScope = false }
            panel = ExtensionSidePanel(
                extensionID: extensionID, scope: scope,
                tab: isTabScope ? tab : nil, windowController: isTabScope ? nil : targetWindow,
                controller: self, configuration: configuration, url: url,
                title: ExtensionManager.shared.displayName(for: extensionID), icon: ext?.icon,
                recency: Self.recencyCounter)
            panels.append(panel)
            log.info("Opened the side panel of \(extensionID, privacy: .public) (\(isTabScope ? "tab" : "window", privacy: .public) panel) in profile \(profile.name, privacy: .public)")
            // One panel in one place: another extension's panel for the same
            // tab (or the same window) makes way, as in Chrome's one side panel.
            for other in panels where other !== panel && other.scope == scope {
                close(other, reason: .replaced)
            }
        }
        Self.reconcile()
        if focus, let webView = panel.webView, let hosting = webView.window {
            hosting.makeFirstResponder(webView)
        }
        return .success(panel)
    }

    /// `sidePanel.open` from the extension: focus follows the user gesture rule.
    @discardableResult
    func openFromExtension(extensionID: String, tab: BrowserTab?,
                           window: BrowserWindowController?) -> Result<ExtensionSidePanel, APIError> {
        open(extensionID: extensionID, tab: tab, window: window,
             focus: consumeUserGesture(extensionID: extensionID))
    }

    /// `sidePanel.close`: the tab's own panel when open, else the default
    /// panel of the window. Not an error when nothing is open.
    func close(extensionID: String, tab: BrowserTab?, window: BrowserWindowController?) {
        let targetWindow = window ?? tab.flatMap(Self.window(showing:))
        var state = state(for: extensionID)
        let closed = state.close(tab: tab?.id, window: targetWindow.map(ObjectIdentifier.init))
        states[extensionID] = state
        for scope in closed {
            if let panel = panel(extensionID: extensionID, scope: scope) { remove(panel, reason: .api) }
        }
        Self.reconcile()
    }

    private static func message(for error: ExtensionSidePanelOpenError) -> String {
        switch error {
        case .missingTarget:
            return "At least one of \"tabId\" and \"windowId\" must be provided"
        case .noActivePanelForTab:
            return "No active side panel for the tab"
        case .noActivePanelForWindow:
            return "No active side panel for the window"
        case .noWindowForTab:
            return "sidePanel.open: the tab is not in a window"
        }
    }

    // MARK: The toolbar action

    /// The user clicked the extension's toolbar action. With
    /// `openPanelOnActionClick` the click toggles the panel beside `tab` and
    /// `action.onClicked` does not fire, as in Chrome; returns false — nothing
    /// done — otherwise.
    func handleActionClick(extensionID: String, tab: BrowserTab?, window: BrowserWindowController) -> Bool {
        guard profile?.extensionContext(for: extensionID) != nil,
              opensPanelOnActionClick(extensionID: extensionID) else { return false }
        if let shown = window.displayedSidePanel, shown.extensionID == extensionID {
            close(shown, reason: .user)
            return true
        }
        if case .failure(let error) = open(extensionID: extensionID, tab: tab, window: window, focus: true) {
            // A tab with no panel of its own and a default that cannot open:
            // nothing to show, and nothing else to do with the click.
            log.info("The toolbar action of \(extensionID, privacy: .public) opens its side panel, but none can open: \(error.message, privacy: .public)")
        }
        return true
    }

    // MARK: Closing

    /// Closes one panel: by the user, by its own page, or by a failed load.
    func close(_ panel: ExtensionSidePanel, reason: ExtensionSidePanelCloseReason) {
        guard panels.contains(where: { $0 === panel }) else { return }
        var state = state(for: panel.extensionID)
        state.didClose(panel.scope)
        states[panel.extensionID] = state
        remove(panel, reason: reason)
        Self.reconcile()
    }

    private func remove(_ panel: ExtensionSidePanel, reason: ExtensionSidePanelCloseReason) {
        panels.removeAll { $0 === panel }
        // Where the keys go when the panel had them: back to the page.
        let hosting = panel.hostingWindow
        let hadFocus = (hosting?.window?.firstResponder as? NSView)?.isDescendant(of: panel.view) ?? false
        panel.teardown()
        if hadFocus { hosting?.restoreWebContentFocus() }
        log.info("Closed the side panel of \(panel.extensionID, privacy: .public): \(reason.rawValue, privacy: .public)")
    }

    /// The extension's context is unloading from this profile (disable,
    /// uninstall, update, reload): its panels close and its options are
    /// forgotten — a reloaded context starts over, as in Chrome.
    func extensionDidUnload(_ extensionID: String) {
        for panel in panels(for: extensionID) { remove(panel, reason: .contextUnloaded) }
        states[extensionID] = nil
        userGestures[extensionID] = nil
        Self.reconcile()
    }

    /// `tab` is closing: its options and its panels go with it.
    fileprivate func forget(tab: BrowserTab) {
        for (extensionID, var state) in states {
            let closed = state.forget(tab: tab.id)
            states[extensionID] = state
            if let closed, let panel = panel(extensionID: extensionID, scope: closed) {
                remove(panel, reason: .tabClosed)
            }
        }
    }

    /// `window` is closing: its window panels close. A tab panel it was
    /// showing belongs to the tab, and only leaves the window.
    fileprivate func forget(window: BrowserWindowController) {
        let key = ObjectIdentifier(window)
        for (extensionID, var state) in states {
            let closed = state.forget(window: key)
            states[extensionID] = state
            if let closed, let panel = panel(extensionID: extensionID, scope: closed) {
                remove(panel, reason: .windowClosed)
            }
        }
    }

    /// Panels whose tab or window is gone without anyone saying so: a tab
    /// that left this profile's lists (moved to another profile, a peek that
    /// was parked), a window that was released.
    private func closeOrphans() {
        guard let profile else {
            for panel in panels { remove(panel, reason: .contextUnloaded) }
            return
        }
        func closeOrphan(_ panel: ExtensionSidePanel, reason: ExtensionSidePanelCloseReason) {
            var state = state(for: panel.extensionID)
            state.didClose(panel.scope)
            states[panel.extensionID] = state
            remove(panel, reason: reason)
        }
        for panel in panels {
            switch panel.scope {
            case .tab:
                guard let tab = panel.tab else {
                    closeOrphan(panel, reason: .tabClosed)
                    continue
                }
                guard let placement = extensionTabPlacement(of: tab, in: .shared) else {
                    // In no list right now — which is also what a tab on its
                    // way from one list to another looks like (moved to
                    // another space, made a favourite): `TabStore` takes it
                    // out, notifies, and only then puts it in, and a window
                    // answering that notification reconciles right here. So
                    // an unlisted tab gets a second look once the mutation is
                    // over, and its panel closes only if it is still unlisted.
                    closeIfStillUnlisted(panel)
                    continue
                }
                if placement.profileID != profile.id {
                    closeOrphan(panel, reason: .tabClosed)
                }
            case .window:
                guard let window = panel.windowController, window.canParkAutomationTabs else {
                    closeOrphan(panel, reason: .windowClosed)
                    continue
                }
            }
        }
    }

    /// Looks at a tab panel whose tab is in no list again on the next turn of
    /// the main queue — after whatever `TabStore` mutation is running — and
    /// closes it if the tab is still in none (`closeOrphans`).
    private func closeIfStillUnlisted(_ panel: ExtensionSidePanel) {
        guard !panel.awaitsPlacementCheck else { return }
        panel.awaitsPlacementCheck = true
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel else { return }
            panel.awaitsPlacementCheck = false
            guard self.panels.contains(where: { $0 === panel }) else { return }
            if let tab = panel.tab, extensionTabPlacement(of: tab, in: .shared) != nil {
                // Listed again: in this profile the panel stays, in another
                // one the reconcile closes it.
                Self.reconcile()
            } else {
                self.close(panel, reason: .tabClosed)
            }
        }
    }

    /// The window `tab` is in, as far as a panel is concerned: the one
    /// showing its live web view, else the one extensions are told it is in.
    static func window(showing tab: BrowserTab) -> BrowserWindowController? {
        if let owner = tab.webView?.window?.windowController as? BrowserWindowController,
           owner.canParkAutomationTabs, !tab.isAutomationParked {
            return owner
        }
        return tab.extensionWindow()
    }

    /// A window for a panel that has to act without one of its own: the key
    /// window when it shows this profile, else the first window that does.
    func fallbackWindow() -> BrowserWindowController? {
        guard let profile else { return nil }
        let windows = extensionBrowserWindows().filter {
            $0.canParkAutomationTabs && $0.activeSpace?.profileID == profile.id
        }
        return windows.first { $0.window?.isKeyWindow == true } ?? windows.first
    }

    // MARK: - Every profile

    static func tabDidClose(_ tab: BrowserTab) {
        guard !allPanels.isEmpty || controllers.allObjects.contains(where: { !$0.states.isEmpty }) else { return }
        for controller in controllers.allObjects { controller.forget(tab: tab) }
        reconcile()
    }

    static func windowWillClose(_ window: BrowserWindowController) {
        for controller in controllers.allObjects { controller.forget(window: window) }
        window.showSidePanel(nil)
        reconcile()
    }

    /// Settles what every browser window shows: each gets the panel it should
    /// be showing now, or none. Run after anything that can change that — a
    /// panel opening or closing, a selection change, a web view changing
    /// owner, a window closing. Cheap with nothing open, and idempotent.
    static func reconcile() {
        guard !isReconciling else { reconcileAgain = true; return }
        isReconciling = true
        defer { isReconciling = false }
        var passes = 0
        repeat {
            reconcileAgain = false
            passes += 1
            for controller in controllers.allObjects where !controller.panels.isEmpty {
                controller.closeOrphans()
            }
            let panels = allPanels
            let windows = extensionBrowserWindows().filter(\.canParkAutomationTabs)
            // A window can still hold the view of a panel that has just closed.
            guard !panels.isEmpty || windows.contains(where: \.isHoldingSidePanelView) else { return }
            // Detach first, then attach: a panel moving from one window to
            // another must not be taken back out by the window it left.
            let wanted = windows.map { ($0, panelToDisplay(in: $0, among: panels)) }
            for (window, panel) in wanted where panel == nil || window.displayedSidePanel !== panel {
                window.showSidePanel(nil)
            }
            for (window, panel) in wanted where panel != nil {
                window.showSidePanel(panel)
            }
        } while reconcileAgain && passes < 4
    }

    /// The panel `window` shows now (`sidePanelToDisplay`).
    static func panelToDisplay(in window: BrowserWindowController,
                               among panels: [ExtensionSidePanel]) -> ExtensionSidePanel? {
        guard let profile = window.activeSpace?.profile else { return nil }
        let mine = panels.filter { $0.controller?.profile === profile }
        let candidates = mine.map {
            ExtensionSidePanelCandidate<UUID, ObjectIdentifier, ObjectIdentifier>(
                id: ObjectIdentifier($0), scope: $0.scope, recency: $0.recency)
        }
        let chosen = sidePanelToDisplay(window: ObjectIdentifier(window),
                                        displayedTabs: window.sidePanelDisplayedTabs.map(\.id),
                                        candidates: candidates,
                                        isDisabledForTab: { id, tabID in
            guard let panel = mine.first(where: { ObjectIdentifier($0) == id }),
                  let controller = panel.controller else { return false }
            return !controller.state(for: panel.extensionID).resolvedOptions(for: tabID).enabled
        })
        return mine.first { ObjectIdentifier($0) == chosen }
    }
}
