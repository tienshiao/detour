import AppKit
import Combine
import WebKit

/// A Quick Detour window (TASK-193.1): one page, no sidebar, for a lookup that
/// should not disturb any space. File > New Quick Detour Window (Opt-Cmd-N)
/// shows the launcher panel (`QuickDetourLauncher`); what is submitted there
/// opens this window already loading it, so it never has an empty page.
///
/// The page is a `BrowserTab` in `TabStore.quickDetourTabs` and in no space
/// (see `TabStore+QuickDetour.swift`), resolved by id so the store stays the
/// one owner. Only this window ever hosts its web view: no other window lists
/// the tab, so there is no ownership hand-off and no snapshot.
///
/// A normal-level window, like Arc's Little Arc; several may be open at once.
/// It is never restored at launch (the session save holds spaces only).
final class QuickDetourWindowController: NSWindowController {

    // MARK: - Open windows

    /// Every open Quick Detour window, oldest first. Holding them here is what
    /// keeps them alive (`AppDelegate` keeps browser windows the same way);
    /// `windowWillClose` lets go.
    private(set) static var openControllers: [QuickDetourWindowController] = []

    /// The open window whose page is the tab with `id`.
    static func controller(forTabID id: UUID) -> QuickDetourWindowController? {
        openControllers.first { $0.tabID == id }
    }

    /// The default size: about Arc's, smaller than a browser window, large
    /// enough for a page laid out for a desktop.
    static let defaultContentSize = NSSize(width: 900, height: 640)
    static let minimumSize = NSSize(width: 480, height: 320)

    /// Opens a Quick Detour on `profile` loading `url`, in front and key.
    /// `sourceSpace` is the space of the window it was opened from, whose
    /// history its palette suggests from when it is the same profile's.
    @discardableResult
    static func open(profile: Profile, sourceSpace: Space? = nil, url: URL,
                     typed: Bool = false) -> QuickDetourWindowController {
        let controller = QuickDetourWindowController(profile: profile, sourceSpace: sourceSpace)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.load(url, typed: typed)
        return controller
    }

    // MARK: - State

    let tabID: UUID
    let profile: Profile
    /// The space whose history the palette suggests from
    /// (`QuickDetour.paletteHistorySpaceID`).
    let paletteHistorySpaceID: UUID
    /// The space Open in names (TASK-193.3 makes it work).
    private let openInSpaceID: UUID?

    var store: TabStore { .shared }

    /// The window's page, while the window is open.
    var tab: BrowserTab? { store.quickDetourTab(withID: tabID) }

    let titleBar = QuickDetourTitleBar()
    let contentContainerView = NSView()
    let findBar = FindBarView()
    private lazy var findSession = FindInPageSession(bar: findBar)
    private let linkStatusBar = LinkStatusBar()
    let toastManager = ToastManager()
    private(set) var commandPaletteView: CommandPaletteView?
    private var paletteScrim: NSView?
    private var tabSubscriptions = Set<AnyCancellable>()
    private let extensionActiveTabTracker = ExtensionActiveTabTracker()
    private var extensionPopovers: [String: ExtensionPopoverController] = [:]
    private var isTornDown = false
    /// The pasteboard Copy Link writes to; a test swaps it.
    var urlPasteboard: NSPasteboard = .general

    private static let scriptHandlerNames = ["linkHover", "editableFieldFocus"]

    // MARK: - Init

    /// - Parameters:
    ///   - configuration: a window a Quick Detour page opened
    ///     (`createWebViewWith`) — the page keeps its opener.
    init(profile: Profile, sourceSpace: Space?, openedWith configuration: WKWebViewConfiguration? = nil) {
        self.tabID = UUID()
        self.profile = profile
        self.paletteHistorySpaceID = QuickDetour.paletteHistorySpaceID(profile: profile, sourceSpace: sourceSpace)
        let profileSpaces = TabStore.shared.spaces.filter { $0.profileID == profile.id && !$0.isIncognito }
        self.openInSpaceID = profile.isIncognito ? nil
            : (sourceSpace.flatMap { space in profileSpaces.first { $0.id == space.id } } ?? profileSpaces.first)?.id

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.minSize = Self.minimumSize
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.title = QuickDetour.displayName
        if profile.isIncognito {
            window.appearance = NSAppearance(named: .darkAqua)
        }
        super.init(window: window)
        window.delegate = self
        Self.cascade(window)

        // An empty compact toolbar centres the traffic lights in a bar as tall
        // as the capsule row, as in the reference.
        window.toolbar = NSToolbar(identifier: "QuickDetourToolbar")
        window.toolbarStyle = .unifiedCompact

        setupViews(in: window)

        // Registered before the tab exists: entering `quickDetourTabs` reports
        // the tab open to the extension contexts, and their `window(for:)`
        // finds this window through the registry.
        Self.openControllers.append(self)
        store.addObserver(self)
        // WebKit lists only the windows it was told about (`didOpenWindow`, or
        // `openWindowsFor` when a context loads); a browser window it learns
        // of on focus, but a Quick Detour is a lookup that may never be
        // focused while an extension asks. Told before the tab, so the tab's
        // `tabs.onCreated` names a window the contexts know.
        for context in profile.extensionContexts.values {
            context.didOpenWindow(self)
        }
        let tab = store.openQuickDetourTab(profile: profile, id: tabID, openedWith: configuration)
        host(tab)
        bind(tab)
        announceExtensionActiveTabIfChanged()

        NotificationCenter.default.addObserver(self, selector: #selector(extensionsDidChange),
                                               name: ExtensionManager.extensionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(extensionsDidChange),
                                               name: ExtensionManager.extensionPinStateDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(extensionActionDidChange(_:)),
                                               name: ExtensionManager.extensionActionDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Each new window steps down and right from the frontmost Quick Detour;
    /// the first one is centred on the screen.
    private static func cascade(_ window: NSWindow) {
        if let previous = openControllers.last?.window, previous.isVisible {
            var frame = previous.frame
            frame.size = window.frame.size
            frame.origin.x += 22
            frame.origin.y = previous.frame.maxY - 22 - frame.height
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
    }

    private func setupViews(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true

        titleBar.setProfile(name: profile.name, isPrivate: profile.isIncognito)
        titleBar.setOpenInSpace(name: openInSpaceID.flatMap { store.space(withID: $0)?.name })
        titleBar.setHost(nil, isSecure: false)
        titleBar.onHostClick = { [weak self] in self?.showPalette(prefill: self?.tab?.url?.absoluteString) }
        titleBar.onCopyLink = { [weak self] in self?.copyCurrentURL(nil) }
        titleBar.onExtensionClick = { [weak self] id, anchor in self?.performExtensionAction(id, anchor: anchor) }
        titleBar.onExtensionsMenuClick = { [weak self] anchor in self?.showExtensionsMenu(from: anchor) }
        contentView.addSubview(titleBar)

        contentContainerView.wantsLayer = true
        contentContainerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentContainerView)

        let titleBarBottom: NSLayoutYAxisAnchor = (window.contentLayoutGuide as? NSLayoutGuide)?.topAnchor
            ?? contentView.topAnchor
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: contentView.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titleBar.bottomAnchor.constraint(equalTo: titleBarBottom),

            contentContainerView.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            contentContainerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentContainerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentContainerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        findBar.delegate = self
        findBar.isHidden = true
        contentContainerView.addSubview(findBar)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: contentContainerView.topAnchor, constant: 12),
            findBar.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor, constant: 12),
        ])

        linkStatusBar.isHidden = true
        linkStatusBar.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.addSubview(linkStatusBar)
        NSLayoutConstraint.activate([
            linkStatusBar.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor, constant: -4),
            linkStatusBar.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor, constant: 4),
            linkStatusBar.widthAnchor.constraint(lessThanOrEqualTo: contentContainerView.widthAnchor, multiplier: 0.5),
            linkStatusBar.heightAnchor.constraint(equalToConstant: 22),
        ])

        toastManager.parentView = contentContainerView
        updateExtensionButtons()
    }

    /// Puts the tab's web view in the content area and makes this window its
    /// delegate. The only host it will ever have.
    private func host(_ tab: BrowserTab) {
        guard let webView = tab.webView else { return }
        tab.ensureWebViewContainer()
        guard let container = tab.webViewContainer else { return }
        container.frame = contentContainerView.bounds
        container.autoresizingMask = [.width, .height]
        contentContainerView.addSubview(container, positioned: .below, relativeTo: findBar)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        let ucc = webView.configuration.userContentController
        for name in Self.scriptHandlerNames {
            ucc.removeScriptMessageHandler(forName: name)
            ucc.add(WeakScriptMessageHandler(self), name: name)
        }
        tab.noteShown()
    }

    /// Follows the page into the title bar and the window title.
    private func bind(_ tab: BrowserTab) {
        tab.$url
            .receive(on: RunLoop.main)
            .sink { [weak self] url in
                self?.titleBar.setHost(Self.displayHost(of: url), isSecure: url?.scheme == "https")
            }
            .store(in: &tabSubscriptions)
        tab.$title
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                guard let self else { return }
                let hasPage = self.tab?.url != nil
                self.window?.title = hasPage && !title.isEmpty ? title : QuickDetour.displayName
            }
            .store(in: &tabSubscriptions)
    }

    /// The host the title bar shows: without `www.`, or the whole URL for a
    /// page that has none.
    static func displayHost(of url: URL?) -> String? {
        guard let url else { return nil }
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - Loading

    /// Loads `url` in the window's page. Typed input arms an internal page the
    /// user asked for, as a browser window's palette does.
    func load(_ url: URL, typed: Bool) {
        guard let tab else { return }
        if let page = InternalPage(url: url), typed {
            tab.loadInternalPage(page)
        } else {
            tab.load(url, typed: typed)
        }
        announceExtensionActiveTabIfChanged()
        restoreWebContentFocus()
    }

    func restoreWebContentFocus() {
        guard commandPaletteView == nil, let webView = tab?.webView, webView.window === window else { return }
        window?.makeFirstResponder(webView)
    }

    /// The page is this window's only tab, so it is the active one whenever
    /// there is a page; the tracker sends one `didActivateTab` per change.
    func announceExtensionActiveTabIfChanged() {
        extensionActiveTabTracker.announce(extensionActiveTab, in: profile)
    }

    // MARK: - Palette

    /// Shows the palette over the page (the host in the title bar, Cmd+L): it
    /// navigates that page in place.
    func showPalette(prefill: String?) {
        guard commandPaletteView == nil else { return }
        let palette = CommandPaletteView()
        palette.delegate = self
        // No open tabs to offer: switching to a tab is another window's
        // business, and this window has one page.
        palette.tabStore = nil
        palette.activeSpaceID = paletteHistorySpaceID
        palette.currentTabID = tabID
        palette.profile = profile
        commandPaletteView = palette

        do {
            let scrim = NSView()
            scrim.wantsLayer = true
            scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
            scrim.translatesAutoresizingMaskIntoConstraints = false
            contentContainerView.addSubview(scrim)
            NSLayoutConstraint.activate([
                scrim.topAnchor.constraint(equalTo: contentContainerView.topAnchor),
                scrim.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor),
                scrim.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
                scrim.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
            ])
            paletteScrim = scrim
        }
        palette.show(in: contentContainerView, initialText: prefill)
    }

    func dismissPalette() {
        commandPaletteView?.removeFromSuperview()
        commandPaletteView = nil
        paletteScrim?.removeFromSuperview()
        paletteScrim = nil
    }

    // MARK: - Actions (main menu, via the responder chain)

    @objc func focusAddressBar(_ sender: Any?) {
        showPalette(prefill: tab?.url?.absoluteString)
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        window?.performClose(sender)
    }

    @objc func copyCurrentURL(_ sender: Any?) {
        guard let urlString = tab?.url?.absoluteString else { return }
        urlPasteboard.clearContents()
        urlPasteboard.setString(urlString, forType: .string)
        toastManager.show(message: "Link copied")
    }

    @objc func reloadPage(_ sender: Any?) {
        tab?.reload()
    }

    @objc func goBack(_ sender: Any?) {
        tab?.webView?.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        tab?.webView?.goForward()
    }

    @objc func zoomIn(_ sender: Any?) {
        guard let webView = tab?.webView else { return }
        webView.pageZoom = min(webView.pageZoom + 0.1, 3.0)
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let webView = tab?.webView else { return }
        webView.pageZoom = max(webView.pageZoom - 0.1, 0.3)
    }

    @objc func zoomActualSize(_ sender: Any?) {
        tab?.webView?.pageZoom = 1.0
    }

    @objc func showWebInspector(_ sender: Any?) {
        guard let inspector = tab?.webView?.value(forKey: "_inspector") as? NSObject else { return }
        inspector.perform(Selector(("show")))
    }

    @objc func showFindBar(_ sender: Any?) {
        guard tab?.webView != nil else { return }
        findBar.alphaValue = 0
        findBar.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            findBar.animator().alphaValue = 1
        }
        findBar.focus()
    }

    @objc func findNext(_ sender: Any?) {
        if findBar.isHidden { showFindBar(sender) }
        let text = findBar.searchField.stringValue
        guard !text.isEmpty else { return }
        performFind(text, backwards: false)
    }

    @objc func findPrevious(_ sender: Any?) {
        if findBar.isHidden { showFindBar(sender) }
        let text = findBar.searchField.stringValue
        guard !text.isEmpty else { return }
        performFind(text, backwards: true)
    }

    @objc func dismissFindBar(_ sender: Any?) {
        findSession.reset()
        window?.makeFirstResponder(tab?.webView)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            findBar.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.findBar.isHidden = true
        })
    }

    /// Escape that nothing in the window took — the find field's editor turns
    /// it into `cancelOperation`, which bubbles up to here: the find bar goes.
    override func cancelOperation(_ sender: Any?) {
        if !findBar.isHidden { dismissFindBar(sender) }
    }

    func performFind(_ text: String, backwards: Bool) {
        guard let webView = tab?.webView else { return }
        findSession.perform(text, backwards: backwards, in: webView)
    }

    // MARK: - Extensions

    private func updateExtensionButtons() {
        let pinned = ExtensionManager.shared.pinnedExtensions(for: profile.id)
        titleBar.setExtensions(pinned.map { (id: $0.id, image: ExtensionManager.iconImage(for: $0.id, ext: $0)) })
        titleBar.extensionsMenuButton.isHidden = ExtensionManager.shared.enabledExtensions(for: profile.id).isEmpty
    }

    @objc private func extensionsDidChange() {
        updateExtensionButtons()
    }

    @objc private func extensionActionDidChange(_ notification: Notification) {
        guard let extensionID = notification.userInfo?["extensionID"] as? String,
              let ext = ExtensionManager.shared.extension(withID: extensionID) else { return }
        titleBar.updateExtensionIcon(extensionID: extensionID, image: ExtensionManager.iconImage(for: extensionID, ext: ext))
    }

    /// An extension's toolbar button: its popup, anchored on the button, or
    /// `action.onClicked` — for this window's page, in this window's profile.
    func performExtensionAction(_ extensionID: String, anchor: NSView) {
        guard let tab, profile.extensionContext(for: extensionID) != nil else { return }
        extensionPopovers[extensionID]?.close()
        let popover = ExtensionPopoverController(extensionID: extensionID, profile: profile, tab: tab)
        // Only this popover's entry: the one it replaced closes after the new
        // one is stored, and must not drop it.
        popover.onClose = { [weak self, weak popover] in
            guard let self, self.extensionPopovers[extensionID] === popover else { return }
            self.extensionPopovers.removeValue(forKey: extensionID)
        }
        extensionPopovers[extensionID] = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// Every extension of the profile, for the ones not pinned.
    private func showExtensionsMenu(from anchor: NSView) {
        let menu = NSMenu()
        for ext in ExtensionManager.shared.enabledExtensions(for: profile.id)
        where profile.extensionContext(for: ext.id) != nil {
            let item = NSMenuItem(title: ExtensionManager.shared.displayName(for: ext.id),
                                  action: #selector(extensionMenuItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ext.id
            let icon = ExtensionManager.iconImage(for: ext.id, ext: ext)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        guard !menu.items.isEmpty else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.minY - 4), in: anchor)
    }

    @objc private func extensionMenuItemChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        performExtensionAction(id, anchor: titleBar.extensionButton(for: id) ?? titleBar.extensionsMenuButton)
    }

    // MARK: - Teardown

    /// Releases everything the window holds of its page, then the page itself:
    /// out of `quickDetourTabs`, its web view and its extension registration
    /// gone (`TabStore.closeQuickDetourTab`). Idempotent; runs from
    /// `windowWillClose` and from the store when the page is closed elsewhere
    /// (an extension's `tabs.remove`, its profile deleted).
    private func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        dismissPalette()
        for popover in extensionPopovers.values { popover.close() }
        extensionPopovers.removeAll()
        tabSubscriptions.removeAll()
        if let webView = tab?.webView {
            let ucc = webView.configuration.userContentController
            for name in Self.scriptHandlerNames { ucc.removeScriptMessageHandler(forName: name) }
            if webView.navigationDelegate === self { webView.navigationDelegate = nil }
            if webView.uiDelegate === self { webView.uiDelegate = nil }
        }
        store.removeObserver(self)
        let closing = tab
        if let closing { store.closeQuickDetourTab(closing) }
        // The window is gone for the contexts that knew it (WebKit is told
        // about a window only by focus or a context load; telling it of the
        // close is harmless for one it never heard of).
        for context in profile.extensionContexts.values {
            context.didCloseWindow(self)
        }
        Self.openControllers.removeAll { $0 === self }
    }
}

// MARK: - NSWindowDelegate

extension QuickDetourWindowController: NSWindowDelegate {
    /// A Private Quick Detour's downloads go with its window, as a Private
    /// window's do, so the ones still in flight are asked about first
    /// (`PrivateDownloadClosePolicy`, TASK-156). A normal one's are listed by
    /// every browser window and never cancelled here.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let manager = DownloadManager.shared
        let closing = PrivateDownloadClosePolicy.Closing.window(downloadScope)
        let inFlight = manager.privateDownloadsInFlight(closing: closing).count
        switch PrivateDownloadClosePolicy.decision(inFlightCount: inFlight) {
        case .close:
            return true
        case .confirm(let prompt):
            guard BrowserWindowController.runPrivateDownloadCloseAlert(prompt) else { return false }
            manager.cancelPrivateDownloads(closing: closing)
            return true
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        announceExtensionActiveTabIfChanged()
    }

    func windowWillClose(_ notification: Notification) {
        tearDown()
    }
}

// MARK: - TabStoreObserver

extension QuickDetourWindowController: TabStoreObserver {
    /// The page was closed from outside the window — an extension's
    /// `tabs.remove`, its profile deleted: the window goes with it.
    func tabStoreDidCloseQuickDetour(_ tab: BrowserTab) {
        guard tab.id == tabID, !isTornDown else { return }
        window?.close()
    }
}

// MARK: - CommandPaletteDelegate

extension QuickDetourWindowController: CommandPaletteDelegate {
    func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String) {
        if let url = AddressInputClassifier.directURL(from: input) {
            submit(url, typed: true)
        } else if let url = profile.searchEngine.searchURL(for: input) {
            submit(url, typed: false)
        }
    }

    func commandPalette(_ palette: CommandPaletteView, didSubmitSearch query: String) {
        guard let url = profile.searchEngine.searchURL(for: query) else { return }
        submit(url, typed: false)
    }

    private func submit(_ url: URL, typed: Bool) {
        dismissPalette()
        load(url, typed: typed)
    }

    /// Escape, or a click outside the palette: back to the page.
    func commandPaletteDidDismiss(_ palette: CommandPaletteView) {
        dismissPalette()
        restoreWebContentFocus()
    }
}

// MARK: - FindBarDelegate

extension QuickDetourWindowController: FindBarDelegate {
    func findBar(_ bar: FindBarView, searchFor text: String, backwards: Bool) {
        performFind(text, backwards: backwards)
    }

    func findBarDidDismiss(_ bar: FindBarView) {
        dismissFindBar(nil)
    }
}

// MARK: - WKScriptMessageHandler

extension QuickDetourWindowController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "linkHover", let urlString = message.body as? String {
            if urlString.isEmpty {
                linkStatusBar.hide()
            } else {
                linkStatusBar.show(url: urlString)
            }
        } else if message.name == "editableFieldFocus", let editing = message.body as? Bool {
            (message.webView as? BrowserWebView)?.isEditingWebContent = editing
        }
    }
}

/// Holds a script message handler weakly: `WKUserContentController` retains
/// the handler it is given, which would keep a closed window alive.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - NSMenuItemValidation

extension QuickDetourWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return tab?.canGoBack ?? false
        case #selector(goForward(_:)): return tab?.canGoForward ?? false
        case #selector(copyCurrentURL(_:)), #selector(reloadPage(_:)), #selector(showFindBar(_:)),
             #selector(findNext(_:)), #selector(findPrevious(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
             #selector(zoomActualSize(_:)), #selector(showWebInspector(_:)):
            return tab?.url != nil
        default: return true
        }
    }
}
