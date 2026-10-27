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
    /// File > Open Quick Detour in Space (Cmd+O) while no Quick Detour is in
    /// front; one that is names its target there.
    static let openInMenuItemTitle = "Open \(QuickDetour.displayName) in Space"
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

    /// Reopens archived Quick Detour `recordID` (the Archived Tabs page,
    /// TASK-193.5): a new window on the record's profile, its page rebuilt
    /// from the record (its address, title and favicon, and its back/forward
    /// list), the record consumed. Nil, changing nothing, for a record that
    /// is not a restorable Quick Detour.
    @discardableResult
    static func restore(recordID: Int64, sourceSpace: Space? = nil, store: TabStore = .shared) -> QuickDetourWindowController? {
        guard let page = store.takeQuickDetourArchiveRecord(id: recordID) else { return nil }
        let space = sourceSpace.flatMap { $0.profileID == page.profile.id ? $0 : nil }
        let controller = QuickDetourWindowController(profile: page.profile, sourceSpace: space, restoring: page)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.restoreWebContentFocus()
        return controller
    }

    // MARK: - State

    /// What closing the window does with its page (TASK-193.5): archived as
    /// closed unless the idle monitor closes it (auto-closed) or a test says
    /// otherwise.
    var closeDisposition: QuickDetourCloseDisposition = .archive(autoClosed: false)

    /// When the window was last used (`QuickDetourIdleState.lastUsedAt`), on
    /// the idle monitor's clock.
    private(set) var lastUsedAt: Date = QuickDetourIdleMonitor.shared.now()

    /// Notes a use now: the idle time starts again. What counts as use
    /// (TASK-193.5): opening (or restoring) the window, the window becoming
    /// or ceasing to be key, a key press, click or scroll in it, and its page
    /// starting or stopping sound. Navigation alone does not — a page can
    /// navigate itself; one the user starts follows input in the window.
    func noteUse() {
        lastUsedAt = QuickDetourIdleMonitor.shared.now()
    }

    /// What the idle rule needs to know about this window now.
    var idleState: QuickDetourIdleState {
        QuickDetourIdleState(lastUsedAt: lastUsedAt, isFrontmost: isFrontmost,
                             isAudible: tab?.isAudible == true, isPrivate: profile.isIncognito,
                             hasSheet: window?.attachedSheet != nil)
    }

    /// The key window, or the front one of Detour's own browser and Quick
    /// Detour windows (Detour may be in the background with it on screen).
    private var isFrontmost: Bool {
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        if window.isKeyWindow { return true }
        let front = NSApp.orderedWindows.first {
            $0.isVisible && !$0.isMiniaturized
                && ($0.windowController is BrowserWindowController || $0.windowController is QuickDetourWindowController)
        }
        return front === window
    }

    /// The idle monitor's close: archived as auto-closed. Never while a sheet
    /// is up, whose completion WebKit is waiting on (the rule says so too).
    func autoClose() {
        guard window?.attachedSheet == nil else { return }
        closeDisposition = .archive(autoClosed: true)
        window?.close()
    }

    /// The window's page. A new one, with a new id, when the profile pill
    /// switches profile (TASK-193.4).
    private(set) var tabID: UUID
    /// The page's profile; the pill switches it (`switchProfile(to:)`).
    private(set) var profile: Profile
    /// The space whose history the palette suggests from
    /// (`QuickDetour.paletteHistorySpaceID`), for the current profile.
    private(set) var paletteHistorySpaceID: UUID
    /// The space of the browser window it was opened from — what Open in
    /// names while it is still there and the same profile's (TASK-193.3).
    let sourceSpaceID: UUID?

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
    private weak var pageSettingsPopover: NSPopover?
    private var isTornDown = false
    /// The pasteboard Copy Link writes to; a test swaps it.
    var urlPasteboard: NSPasteboard = .general

    private static let scriptHandlerNames = ["linkHover", "editableFieldFocus"]

    // MARK: - Init

    /// - Parameters:
    ///   - configuration: a window a Quick Detour page opened
    ///     (`createWebViewWith`) — the page keeps its opener.
    ///   - restoring: a closed Quick Detour from the archive (TASK-193.5): its
    ///     page comes back with its address, title, favicon and back/forward list.
    init(profile: Profile, sourceSpace: Space?, openedWith configuration: WKWebViewConfiguration? = nil,
         restoring archived: QuickDetourArchivedPage? = nil) {
        self.tabID = UUID()
        self.profile = profile
        self.paletteHistorySpaceID = QuickDetour.paletteHistorySpaceID(profile: profile, sourceSpace: sourceSpace)
        self.sourceSpaceID = sourceSpace?.id

        let window = QuickDetourWindow(
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
        // A key press, click or scroll in the window is a use (TASK-193.5).
        window.onUserInput = { [weak self] in self?.noteUse() }
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
        let tab = store.openQuickDetourTab(profile: profile, id: tabID, openedWith: configuration, restoring: archived)
        host(tab)
        bind(tab)
        announceExtensionActiveTabIfChanged()

        NotificationCenter.default.addObserver(self, selector: #selector(extensionsDidChange),
                                               name: ExtensionManager.extensionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(extensionsDidChange),
                                               name: ExtensionManager.extensionPinStateDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(extensionActionDidChange(_:)),
                                               name: ExtensionManager.extensionActionDidChangeNotification, object: nil)
        // `TabStore.updateProfile`'s only signal: a profile's settings (its
        // name among them) were saved.
        NotificationCenter.default.addObserver(self, selector: #selector(profileDidChange(_:)),
                                               name: .init("UserAgentDidChange"), object: nil)
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
        titleBar.onProfileClick = { [weak self] anchor in self?.showProfileMenu(from: anchor) }
        titleBar.onOpenIn = { [weak self] in self?.openInDefaultSpace(nil) }
        titleBar.onOpenInMenu = { [weak self] anchor in self?.showOpenInMenu(from: anchor) }
        updateOpenIn()
        titleBar.setHost(nil, isSecure: false)
        titleBar.onHostClick = { [weak self] in self?.showPalette(prefill: self?.tab?.url?.absoluteString) }
        titleBar.onCopyLink = { [weak self] in self?.copyCurrentURL(nil) }
        titleBar.onExtensionClick = { [weak self] id, anchor in self?.performExtensionAction(id, anchor: anchor) }
        titleBar.onPageSettingsClick = { [weak self] anchor in self?.showPageSettings(from: anchor) }
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
        // Sound starting or stopping is a use; while it plays the window is in
        // use (`idleState.isAudible`).
        tab.$isPlayingAudio
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.noteUse() }
            .store(in: &tabSubscriptions)
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
        // No browser around it to say where the page goes (TASK-210).
        palette.placeholder = "Search or enter a URL"
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
        // Below the button: a button is flipped, so that is its maxY edge.
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    // MARK: - Page settings (TASK-210)

    /// The main window's site settings, for this window's page and profile:
    /// content blocking with the count and the profile's extensions with
    /// their pins. No picture in picture or dev mode: a Quick Detour has no
    /// tab switching or sidebar for them to act on (TASK-213).
    func makePageSettings() -> SettingsPopoverViewController {
        let page = tab
        return SettingsPopoverViewController.forPage(
            url: page?.url, blockedCount: page?.blockedCount ?? 0, profileID: profile.id,
            showsTabSwitches: false,
            pages: { [weak self] in self?.tab.map { [$0] } ?? [] },
            openExtension: { [weak self] extensionID in
                guard let self else { return }
                // The popup takes the settings' place on the button.
                self.pageSettingsPopover?.close()
                self.performExtensionAction(extensionID, anchor: self.titleBar.extensionButton(for: extensionID)
                                            ?? self.titleBar.pageSettingsButton)
            })
    }

    private func showPageSettings(from anchor: NSView) {
        pageSettingsPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = makePageSettings()
        pageSettingsPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    // MARK: - Open in (TASK-193.3)

    /// Carries out a placement for Open in: the Air Traffic Control rule
    /// (`AppDelegate.placeTab`), handing `makeTab` the receiving space,
    /// running `didSelect` once the window has selected the tab, and
    /// returning that window.
    static func placeTab(_ decision: LinkRouteDecision, makeTab: (Space) -> BrowserTab?,
                         didSelect: ((BrowserWindowController, BrowserTab) -> Void)? = nil) -> BrowserWindowController? {
        (NSApp.delegate as? AppDelegate)?.placeTab(routedTo: decision, makeTab: makeTab, didSelect: didSelect)
    }

    /// The button and its dropdown, from the store as it is now: the source
    /// space can have been deleted, and another space used, since the window
    /// opened.
    var openInMenu: QuickDetourOpenInMenu {
        store.quickDetourOpenInMenu(profile: profile, sourceSpaceID: sourceSpaceID)
    }

    func updateOpenIn() {
        let menu = openInMenu
        titleBar.setOpenIn(destination: menu.destinationName, reloads: menu.defaultReloads,
                           hasDropdown: menu.hasDropdown)
    }

    /// Cmd+O and the button: the default target.
    @objc func openInDefaultSpace(_ sender: Any?) {
        guard let target = openInMenu.defaultTarget else { return }
        open(in: target)
    }

    /// Moves the page to `target` and closes the window (TASK-193.3).
    ///
    /// - A space of this window's profile: the page itself is handed over
    ///   (`handOver`), intact.
    /// - Another profile's space: its address is opened there in a new tab
    ///   (`reopen`) — that profile's data store, so its cookies and sign-ins,
    ///   and no back/forward history — and this window closes with its page.
    /// - `.privateWindow`, for a Private Quick Detour: handed over to the most
    ///   recent Private window, else a new one; the same Private store.
    ///
    /// Placed by Air Traffic Control's rule (`AppDelegate.placeTab`). Refused,
    /// leaving everything as it was, across the Private boundary, for a space
    /// that is gone, with no page, or while a sheet is up: a script dialog,
    /// file panel or permission prompt whose completion handler WebKit is
    /// waiting on would close with the window unanswered.
    func open(in target: QuickDetourOpenInTarget) {
        guard window?.attachedSheet == nil else { return }
        switch target {
        case .privateWindow:
            guard profile.isIncognito else { return }
            handOver(routedTo: .privateWindow)
        case .space(let spaceID):
            guard !profile.isIncognito, let space = store.space(withID: spaceID), !space.isIncognito else { return }
            if space.profileID == profile.id {
                handOver(routedTo: .openInSpace(spaceID))
            } else {
                reopen(routedTo: .openInSpace(spaceID))
            }
        }
    }

    /// The same-profile move: the page leaves this window, the store moves
    /// the tab into the receiving space as the placement opens or switches its
    /// window (`TabStore.moveQuickDetourTab`), the browser window selects it
    /// and takes the web view, and only then does this window close.
    ///
    /// The order is what keeps the page alive. This window lets go of the web
    /// view first (`releasePage`): delegates, script handlers, and its
    /// container out of the content view, so the browser window claims it at
    /// once instead of showing a snapshot of a page still parented here. Once
    /// moved, the tab no longer resolves as this window's (`tab` is nil), so
    /// the close's `tearDown` closes nothing in the store and lists no tab to
    /// WebKit's `didCloseWindow` — only the window goes.
    private func handOver(routedTo decision: LinkRouteDecision) {
        guard let page = tab, page.webView != nil else { return }
        releasePage(page)
        let receiving = Self.placeTab(decision, makeTab: { [store] space in
            store.moveQuickDetourTab(page, into: space, announcingMove: false) ? page : nil
        }, didSelect: { [weak self] _, moved in
            // Selected in its new window: detached from this one, attached
            // there, before the window announces it active.
            ExtensionTabLifecycle.didMove(moved, fromIndex: 0, in: self)
        })
        guard receiving != nil, !store.isQuickDetourTab(page) else {
            // Nothing took it (a window or space gone meanwhile): it stays.
            host(page)
            bind(page)
            restoreWebContentFocus()
            return
        }
        window?.close()
    }

    /// The cross-profile case: a new tab of the other profile's space on the
    /// page's address; this window then closes, taking its page down.
    private func reopen(routedTo decision: LinkRouteDecision) {
        guard let url = tab?.url else { return }
        let receiving = Self.placeTab(decision, makeTab: { [store] space in
            // An internal page the user had opened here (typed) is opened
            // the same way there; `addTab(in:url:)` refuses the scheme.
            InternalPage(url: url).map { store.addTab(in: space, internalPage: $0) }
                ?? store.addTab(in: space, url: url)
        })
        guard receiving != nil else { return }
        // The page lives on in the space: not a close for the archive.
        closeDisposition = .discard
        window?.close()
    }

    /// Lets go of what this window holds of the page before it moves: the
    /// palette, the find bar (its matches cleared), popovers and the link
    /// status, the page's subscriptions here, the delegates and script
    /// handlers on its web view, and its container in the content view.
    private func releasePage(_ page: BrowserTab) {
        letGo(of: page)
        if !findBar.isHidden {
            findSession.reset()
            findBar.isHidden = true
        }
        linkStatusBar.hide()
        page.webViewContainer?.removeFromSuperview()
    }

    /// What both a hand-over (`releasePage`) and the close (`tearDown`) drop:
    /// the palette, popovers, the page's subscriptions here, and this
    /// window's script handlers and delegates on its web view.
    private func letGo(of page: BrowserTab?) {
        dismissPalette()
        for popover in extensionPopovers.values { popover.close() }
        extensionPopovers.removeAll()
        pageSettingsPopover?.close()
        tabSubscriptions.removeAll()
        if let webView = page?.webView {
            let ucc = webView.configuration.userContentController
            for name in Self.scriptHandlerNames { ucc.removeScriptMessageHandler(forName: name) }
            if webView.navigationDelegate === self { webView.navigationDelegate = nil }
            if webView.uiDelegate === self { webView.uiDelegate = nil }
        }
    }

    /// The dropdown: the spaces grouped by profile, the window's own first
    /// (`QuickDetour.openInMenu`). Another profile's spaces say in their
    /// tooltip that they reload; the default one carries Cmd+O.
    func makeOpenInMenu() -> NSMenu {
        let model = openInMenu
        let menu = NSMenu()
        menu.autoenablesItems = false
        for section in model.sections {
            if model.showsSectionHeaders {
                menu.addItem(NSMenuItem.sectionHeader(title: section.title))
            }
            for item in section.items {
                let menuItem = NSMenuItem(title: "\(item.emoji) \(item.name)",
                                          action: #selector(openInMenuItemChosen(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = item.spaceID
                if item.reloads {
                    menuItem.toolTip = "Opens this address in \(section.title)'s \(item.name): its cookies and "
                        + "sign-ins, without this page's back and forward history"
                }
                if item.isDefault {
                    menuItem.keyEquivalent = "o"
                    menuItem.keyEquivalentModifierMask = .command
                }
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    static func resetOpenInMenuItemTitle() {
        let selector = #selector(openInDefaultSpace(_:))
        for top in NSApp.mainMenu?.items ?? [] {
            for item in top.submenu?.items ?? [] where item.action == selector {
                item.title = openInMenuItemTitle
            }
        }
    }

    private func showOpenInMenu(from anchor: NSView) {
        let menu = makeOpenInMenu()
        guard !menu.items.isEmpty else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.minY - 4), in: anchor)
    }

    @objc private func openInMenuItemChosen(_ sender: NSMenuItem) {
        guard let spaceID = sender.representedObject as? UUID else { return }
        open(in: .space(spaceID))
    }

    // MARK: - The profile pill (TASK-193.4)

    /// The question asked before leaving Private would cancel Private
    /// downloads; a test answers it.
    static var runProfileSwitchAlert: (PrivateDownloadClosePolicy.Prompt) -> Bool =
        BrowserWindowController.runPrivateDownloadCloseAlert

    /// The pill's menu model, from the store's profiles as they are now.
    var profileMenu: QuickDetourProfileMenu {
        store.quickDetourProfileMenu(windowProfile: profile)
    }

    /// The pill's menu: the profiles, Private last after a separator, the
    /// window's own checked (`QuickDetour.profileMenu`). Another profile's
    /// item says in its tooltip what a switch loses.
    func makeProfileMenu() -> NSMenu {
        let model = profileMenu
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, item) in model.items.enumerated() {
            if index == model.separatorIndex { menu.addItem(.separator()) }
            let menuItem = NSMenuItem(title: item.name, action: #selector(profileMenuItemChosen(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.profileID
            menuItem.state = item.isChecked ? .on : .off
            menuItem.image = QuickDetourTitleBar.profileSymbol(isPrivate: item.isPrivate)
            if !item.isChecked {
                menuItem.toolTip = "Reload this page in \(item.name): its cookies and sign-ins, without this page's "
                    + "back and forward history"
            }
            menu.addItem(menuItem)
        }
        return menu
    }

    private func showProfileMenu(from anchor: NSView) {
        guard window?.attachedSheet == nil else { return }
        let menu = makeProfileMenu()
        guard !menu.items.isEmpty else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.minY - 4), in: anchor)
    }

    @objc private func profileMenuItemChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let target = store.profile(withID: id) else { return }
        switchProfile(to: target)
    }

    /// The profile pill (TASK-193.4): reloads the page's address on `target`,
    /// in a new web view on that profile's data store, in this same window.
    /// Returns whether it switched.
    ///
    /// Why a new page rather than a new data store: a web view's data store
    /// is fixed when it is made, so the page on another profile is another
    /// web view, and with it another `BrowserTab`
    /// (`TabStore.replaceQuickDetourTab`): the old one is closed, which is
    /// what its profile's extensions, history and Private session must see,
    /// and the new one opened, as on a new Quick Detour. The window stays,
    /// with its frame, its place among the windows and its source space.
    ///
    /// - The address is `tab.url`: the page's own, also mid-load or behind an
    ///   error page; an internal page is reopened as one. The back/forward
    ///   history, form text, scroll position and `window.opener` are lost.
    /// - Extensions: the old profile's contexts hear the tab and then the
    ///   popup window close; the new profile's hear a popup window open and
    ///   then the tab.
    /// - Private: leaving it asks first when Private downloads are still
    ///   running (`QuickDetour.profileSwitchDecision`); a yes cancels them,
    ///   as closing the window would. Into Private the window turns dark and
    ///   Open in names a Private window.
    ///
    /// Refused, leaving everything as it was, for the same profile or a
    /// deleted one, without a page, or while a sheet is up: a script dialog,
    /// file panel or permission prompt whose completion WebKit is waiting on
    /// would be left with its web view gone.
    @discardableResult
    func switchProfile(to target: Profile) -> Bool {
        guard !isTornDown, window?.attachedSheet == nil, let page = tab else { return false }
        let manager = DownloadManager.shared
        let closing = PrivateDownloadClosePolicy.Closing.window(downloadScope)
        let inFlight = profile.isIncognito ? manager.privateDownloadsInFlight(closing: closing).count : 0
        switch QuickDetour.profileSwitchDecision(from: TabStore.openInSnapshot(of: profile),
                                                 to: TabStore.openInSnapshot(of: target),
                                                 privateDownloadsInFlight: inFlight) {
        case .stay:
            return false
        case .switchProfile:
            break
        case .confirm(let prompt):
            guard Self.runProfileSwitchAlert(prompt) else { return false }
            // The question ran a modal session: the page or the profile can
            // have gone meanwhile, and the page can have put up a sheet (WebKit
            // keeps delivering its messages while the alert runs).
            guard !isTornDown, tab === page, !target.isDeleted, window?.attachedSheet == nil else { return false }
            manager.cancelPrivateDownloads(closing: closing)
        }

        let address = page.url
        let oldProfile = profile
        releasePage(page)
        let newTabID = UUID()
        let replacement = store.replaceQuickDetourTab(page, withPageOn: target, id: newTabID) { [self] in
            // Neither page is listed now: the old profile's contexts are told
            // the window closed (its tab is already reported closed), then the
            // window takes the new profile and its contexts are told it
            // opened, before the new tab enters the list and is reported in it.
            for context in oldProfile.extensionContexts.values {
                context.didCloseWindow(self)
            }
            profile = target
            tabID = newTabID
            paletteHistorySpaceID = QuickDetour.paletteHistorySpaceID(
                profile: target, sourceSpace: sourceSpaceID.flatMap { store.space(withID: $0) })
            for context in target.extensionContexts.values {
                context.didOpenWindow(self)
            }
        }
        guard let replacement else {
            host(page)
            bind(page)
            restoreWebContentFocus()
            return false
        }
        applyProfile()
        host(replacement)
        bind(replacement)
        if let address { replacement.loadRecordedURL(address) }
        announceExtensionActiveTabIfChanged()
        restoreWebContentFocus()
        return true
    }

    /// What follows the profile: the pill, the window's appearance (dark for
    /// Private, as a Private window is), Open in and the extension buttons.
    private func applyProfile() {
        titleBar.setProfile(name: profile.name, isPrivate: profile.isIncognito)
        window?.appearance = profile.isIncognito ? NSAppearance(named: .darkAqua) : nil
        updateOpenIn()
        updateExtensionButtons()
    }

    @objc private func profileDidChange(_ notification: Notification) {
        guard notification.userInfo?["profileID"] as? UUID == profile.id else { return }
        titleBar.setProfile(name: profile.name, isPrivate: profile.isIncognito)
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
        letGo(of: tab)
        store.removeObserver(self)
        let closing = tab
        if let closing { store.closeQuickDetourTab(closing, disposition: closeDisposition) }
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
        noteUse()
        announceExtensionActiveTabIfChanged()
        // Another space may have been used since (the most recent one).
        updateOpenIn()
    }

    /// The File menu's Cmd+O item named this window's target while it was
    /// key (`validateMenuItem`); once it is not, the item is disabled and
    /// goes back to its general title.
    func windowDidResignKey(_ notification: Notification) {
        // Key until now: in use until now.
        noteUse()
        Self.resetOpenInMenuItemTitle()
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

    /// A space added, deleted or renamed: Open in may name another.
    func tabStoreDidUpdateSpaces() {
        updateOpenIn()
    }

    func tabStoreDidAddProfile(_ profile: Profile) {
        updateOpenIn()
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
        case #selector(openInDefaultSpace(_:)):
            let menu = openInMenu
            menuItem.title = menu.destinationName.map { "Open in \($0)" } ?? Self.openInMenuItemTitle
            // Another profile's space reopens the address, so it needs one.
            return menu.defaultTarget != nil && tab?.webView != nil && (!menu.defaultReloads || tab?.url != nil)
                && window?.attachedSheet == nil
        case #selector(copyCurrentURL(_:)), #selector(reloadPage(_:)), #selector(showFindBar(_:)),
             #selector(findNext(_:)), #selector(findPrevious(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
             #selector(zoomActualSize(_:)), #selector(showWebInspector(_:)):
            return tab?.url != nil
        default: return true
        }
    }
}

/// The Quick Detour window: tells its controller of the user's input, which
/// the idle auto-close counts as use (TASK-193.5). A scroll reaches a window
/// that is not key, so it counts there too.
final class QuickDetourWindow: NSWindow {
    var onUserInput: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify, .swipe:
            onUserInput?()
        default:
            break
        }
        super.sendEvent(event)
    }
}
