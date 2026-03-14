import AppKit
import WebKit
import Combine

extension Notification.Name {
    static let webViewOwnershipChanged = Notification.Name("webViewOwnershipChanged")
}

class BrowserWindowController: NSWindowController {
    private let splitViewController = NSSplitViewController()
    private let tabSidebar = TabSidebarViewController()
    private let contentContainerView = NSView()
    private var sidebarItem: NSSplitViewItem!
    private var contentItem: NSSplitViewItem!
    private var sidebarCollapseObservation: NSKeyValueObservation?
    private var sidebarAutoHides = false
    private var sidebarOpenedByHover = false
    private var autoHideWorkItem: DispatchWorkItem?

    var selectedTabID: UUID?
    private var activeTabSubscriptions = Set<AnyCancellable>()
    private var snapshotImageView: NSImageView?
    private var ownsWebView = false
    private var snapshotSubscription: AnyCancellable?

    private let findBar = FindBarView()
    private let dragHandle = WindowDragView()
    private let linkStatusBar = LinkStatusBar()
    private var findBarTopConstraint: NSLayoutConstraint?
    private var webViewTopConstraint: NSLayoutConstraint?
    private var findMatchCount = 0
    private var findMatchIndex = 0
    private var lastFindQuery = ""

    private var commandPaletteView: CommandPaletteView?
    private var commandPaletteNavigatesInPlace = false
    private var splitScrimView: NSView?
    private var contentScrimView: NSView?

    private(set) var isIncognito = false
    private var incognitoSpaceID: UUID?

    enum ContextMenuLinkAction {
        case none, openInNewTab, openInNewWindow
    }
    var contextMenuLinkAction: ContextMenuLinkAction = .none

    private var peekOverlayView: PeekOverlayView?
    private var peekWebView: WKWebView?
    private var peekWebViewTopConstraint: NSLayoutConstraint?
    private var peekWebViewBottomConstraint: NSLayoutConstraint?
    private var peekWebViewLeadingConstraint: NSLayoutConstraint?
    private var peekWebViewTrailingConstraint: NSLayoutConstraint?

    private var store: TabStore { TabStore.shared }

    // MARK: - Per-window space state

    private(set) var activeSpaceID: UUID?

    var activeSpace: Space? {
        guard let activeSpaceID else { return nil }
        return store.space(withID: activeSpaceID)
    }

    private var currentTabs: [BrowserTab] {
        activeSpace?.tabs ?? []
    }

    private var selectedTab: BrowserTab? {
        guard let selectedTabID else { return nil }
        return activeSpace?.pinnedTabs.first { $0.id == selectedTabID }
            ?? currentTabs.first { $0.id == selectedTabID }
    }

    convenience init(incognito: Bool) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        if !incognito {
            window.setFrameAutosaveName("BrowserWindow")
        }
        window.minSize = NSSize(width: 600, height: 400)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true

        if incognito {
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(white: 0.12, alpha: 1)
        }

        self.init(window: window)
        self.isIncognito = incognito

        setupToolbar()
        setupSplitView()
        setupDragHandle()
        setupFindBar()
        setupLinkStatusBar()

        window.delegate = self

        store.addObserver(self)
        DownloadManager.shared.addObserver(self)

        if incognito {
            let space = store.addIncognitoSpace()
            incognitoSpaceID = space.id
            activeSpaceID = space.id
            tabSidebar.isIncognito = true
            tabSidebar.activeSpaceID = activeSpaceID
            tabSidebar.tabs = currentTabs
            tabSidebar.tintColor = space.color
            tabSidebar.updateSpaceButtons(spaces: [space], activeSpaceID: space.id)
            deselectAllTabs()
            window.title = "Private Browsing"
        } else {
            tabSidebar.activeSpaceID = activeSpaceID
            tabSidebar.pinnedTabs = activeSpace?.pinnedTabs ?? []
            tabSidebar.tabs = currentTabs

            // Apply initial space UI
            if let space = activeSpace {
                tabSidebar.tintColor = space.color
            }
            tabSidebar.updateSpaceButtons(spaces: store.spaces, activeSpaceID: activeSpaceID)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWebViewOwnershipChanged(_:)),
            name: .webViewOwnershipChanged,
            object: nil
        )
    }

    deinit {
        store.removeObserver(self)
        DownloadManager.shared.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Space Switching (per-window)

    func setActiveSpace(id: UUID) {
        guard let space = store.space(withID: id), activeSpaceID != id else { return }

        // Save current tab selection for the old space
        activeSpace?.selectedTabID = selectedTabID

        // Dismiss peek overlay on space switch
        dismissPeekOverlay()

        activeSpaceID = id
        tabSidebar.activeSpaceID = id
        if !isIncognito {
            store.lastActiveSpaceID = id
        }

        tabSidebar.setTabs(pinned: space.pinnedTabs, normal: space.tabs)
        tabSidebar.tintColor = space.color
        tabSidebar.updateSpaceButtons(spaces: store.spaces, activeSpaceID: id)

        // Restore the new space's selected tab
        if let savedTabID = space.selectedTabID,
           space.tabs.contains(where: { $0.id == savedTabID }) || space.pinnedTabs.contains(where: { $0.id == savedTabID }) {
            selectTab(id: savedTabID)
        } else if let firstTab = space.pinnedTabs.first ?? space.tabs.first {
            selectTab(id: firstTab.id)
        } else {
            deselectAllTabs()
        }

        store.scheduleSave()
    }

    // MARK: - Setup

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "BrowserToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    private func setupSplitView() {
        tabSidebar.delegate = self

        sidebarItem = NSSplitViewItem(sidebarWithViewController: tabSidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 350
        sidebarItem.canCollapse = true
        splitViewController.addSplitViewItem(sidebarItem)

        let contentVC = NSViewController()
        contentVC.view = contentContainerView
        contentContainerView.wantsLayer = true
        contentItem = NSSplitViewItem(viewController: contentVC)
        splitViewController.addSplitViewItem(contentItem)

        sidebarCollapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
            guard let self, let collapsed = change.newValue else { return }
            if collapsed {
                self.sidebarOpenedByHover = false
                self.setTrafficLightsHidden(true, animated: false)
            } else {
                self.setTrafficLightsHidden(false, animated: true)
            }
        }

        window?.contentViewController = splitViewController

        setupEdgeHoverTracking()
    }

    private func setTrafficLightsHidden(_ hidden: Bool, animated: Bool) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        if hidden {
            for type in buttons {
                window?.standardWindowButton(type)?.isHidden = true
                window?.standardWindowButton(type)?.alphaValue = 0
            }
        } else {
            for type in buttons {
                let button = window?.standardWindowButton(type)
                button?.alphaValue = 0
                button?.isHidden = false
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated ? 0.25 : 0
                for type in buttons {
                    window?.standardWindowButton(type)?.animator().alphaValue = 1
                }
            }
        }
    }

    private func setupEdgeHoverTracking() {
        let edgeView = NSView()
        edgeView.translatesAutoresizingMaskIntoConstraints = false
        splitViewController.view.addSubview(edgeView)
        NSLayoutConstraint.activate([
            edgeView.leadingAnchor.constraint(equalTo: splitViewController.view.leadingAnchor),
            edgeView.topAnchor.constraint(equalTo: splitViewController.view.topAnchor),
            edgeView.bottomAnchor.constraint(equalTo: splitViewController.view.bottomAnchor),
            edgeView.widthAnchor.constraint(equalToConstant: 5),
        ])
        let edgeArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: ["zone": "edge"]
        )
        edgeView.addTrackingArea(edgeArea)

        let sidebarArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: ["zone": "sidebar"]
        )
        tabSidebar.view.addTrackingArea(sidebarArea)
    }

    private func toggleSidebarAutoHide() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        sidebarOpenedByHover = false
        sidebarAutoHides.toggle()

        if #available(macOS 26.0, *) {
            contentItem.automaticallyAdjustsSafeAreaInsets = sidebarAutoHides
        }

        if sidebarAutoHides {
            if !sidebarItem.isCollapsed {
                splitViewController.toggleSidebar(nil)
            }
        } else {
            if sidebarItem.isCollapsed {
                splitViewController.toggleSidebar(nil)
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let userInfo = event.trackingArea?.userInfo,
              let zone = userInfo["zone"] as? String else { return }
        if zone == "edge" && sidebarAutoHides && sidebarItem.isCollapsed {
            sidebarOpenedByHover = true
            splitViewController.toggleSidebar(nil)
        } else if zone == "sidebar" && sidebarOpenedByHover {
            autoHideWorkItem?.cancel()
            autoHideWorkItem = nil
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard let userInfo = event.trackingArea?.userInfo,
              let zone = userInfo["zone"] as? String else { return }
        if zone == "sidebar" && sidebarOpenedByHover {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.sidebarOpenedByHover else { return }
                self.sidebarOpenedByHover = false
                self.splitViewController.toggleSidebar(nil)
            }
            autoHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
    }

    private func setupDragHandle() {
        dragHandle.wantsLayer = true
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.addSubview(dragHandle)
        NSLayoutConstraint.activate([
            dragHandle.topAnchor.constraint(equalTo: contentContainerView.topAnchor),
            dragHandle.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
            dragHandle.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
            dragHandle.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    private func setupFindBar() {
        findBar.delegate = self
        findBar.isHidden = true
        findBar.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.addSubview(findBar)

        findBarTopConstraint = findBar.topAnchor.constraint(equalTo: contentContainerView.topAnchor)
        NSLayoutConstraint.activate([
            findBarTopConstraint!,
            findBar.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
        ])
    }

    private func setupLinkStatusBar() {
        linkStatusBar.isHidden = true
        linkStatusBar.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.addSubview(linkStatusBar)
        NSLayoutConstraint.activate([
            linkStatusBar.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor, constant: -4),
            linkStatusBar.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor, constant: 4),
            linkStatusBar.widthAnchor.constraint(lessThanOrEqualTo: contentContainerView.widthAnchor, multiplier: 0.5),
            linkStatusBar.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    // MARK: - Find Bar Actions

    @objc func showFindBar(_ sender: Any?) {
        findBar.isHidden = false
        updateWebViewTopConstraint()
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
        findBar.isHidden = true
        findBar.searchField.stringValue = ""
        findBar.updateResultLabel("")
        lastFindQuery = ""
        findMatchCount = 0
        findMatchIndex = 0
        updateWebViewTopConstraint()
        window?.makeFirstResponder(selectedTab?.webView)
    }

    private func performFind(_ text: String, backwards: Bool) {
        guard let webView = selectedTab?.webView else { return }

        let isNewQuery = text != lastFindQuery
        if isNewQuery {
            lastFindQuery = text
            findMatchIndex = 0
            countMatches(for: text, in: webView)
        }

        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        webView.find(text, configuration: config) { [weak self] result in
            guard let self else { return }
            if result.matchFound {
                if !isNewQuery {
                    if backwards {
                        self.findMatchIndex -= 1
                        if self.findMatchIndex < 1 { self.findMatchIndex = self.findMatchCount }
                    } else {
                        self.findMatchIndex += 1
                        if self.findMatchIndex > self.findMatchCount { self.findMatchIndex = 1 }
                    }
                }
                self.updateFindLabel()
            } else {
                self.findMatchCount = 0
                self.findMatchIndex = 0
                self.findBar.updateResultLabel("Not found")
            }
        }
    }

    private func countMatches(for text: String, in webView: WKWebView) {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let js = """
        (function() {
            var t = '\(escaped)'.toLowerCase();
            var body = document.body.innerText.toLowerCase();
            var count = 0, pos = 0;
            while ((pos = body.indexOf(t, pos)) !== -1) { count++; pos += t.length; }
            return count;
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, self.lastFindQuery == text else { return }
            self.findMatchCount = (result as? Int) ?? 0
            if self.findMatchCount > 0 {
                self.findMatchIndex = 1
            }
            self.updateFindLabel()
        }
    }

    private func updateFindLabel() {
        if findMatchCount > 0 {
            findBar.updateResultLabel("\(findMatchIndex) of \(findMatchCount)")
        } else {
            findBar.updateResultLabel("Not found")
        }
    }

    private func updateWebViewTopConstraint() {
        let topOffset: CGFloat = findBar.isHidden ? 0 : findBar.frame.height
        let bounds = contentContainerView.bounds

        for subview in contentContainerView.subviews where subview !== findBar && subview !== dragHandle && !(subview is PeekOverlayView) {
            if subview is WKWebView {
                subview.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - topOffset)
            } else if subview is NSImageView {
                webViewTopConstraint?.isActive = false
                if findBar.isHidden {
                    webViewTopConstraint = subview.topAnchor.constraint(equalTo: contentContainerView.topAnchor)
                } else {
                    webViewTopConstraint = subview.topAnchor.constraint(equalTo: findBar.bottomAnchor)
                }
                webViewTopConstraint?.isActive = true
            }
        }
    }

    // MARK: - Tab Selection & WebView Ownership

    func selectTab(id: UUID) {
        let isPinnedTab = activeSpace?.pinnedTabs.contains(where: { $0.id == id }) ?? false
        let isNormalTab = currentTabs.contains(where: { $0.id == id })
        guard isPinnedTab || isNormalTab else { return }

        dismissCommandPalette()
        dismissPeekOverlay()

        if let previousTab = selectedTab {
            if ownsWebView {
                previousTab.takeSnapshot()
            }
        }
        removeContentViews()

        selectedTabID = id
        activeSpace?.selectedTabID = id
        activeTabSubscriptions.removeAll()
        dragHandle.isHidden = false

        guard let tab = selectedTab else { return }

        tab.$url
            .receive(on: RunLoop.main)
            .sink { [weak self] url in
                self?.tabSidebar.fauxAddressBar.displayText = url?.host ?? ""
                self?.tabSidebar.fauxAddressBar.isSecure = url?.scheme == "https" || url == nil
            }
            .store(in: &activeTabSubscriptions)

        tab.$canGoBack
            .receive(on: RunLoop.main)
            .sink { [weak self] canGoBack in
                self?.tabSidebar.backButton.isEnabled = canGoBack
            }
            .store(in: &activeTabSubscriptions)

        tab.$canGoForward
            .receive(on: RunLoop.main)
            .sink { [weak self] canGoForward in
                self?.tabSidebar.forwardButton.isEnabled = canGoForward
            }
            .store(in: &activeTabSubscriptions)

        tab.$title
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                self?.window?.title = title
            }
            .store(in: &activeTabSubscriptions)

        if let index = activeSpace?.pinnedTabs.firstIndex(where: { $0.id == id }) {
            tabSidebar.selectedPinnedTabIndex = index
        } else if let index = currentTabs.firstIndex(where: { $0.id == id }) {
            tabSidebar.selectedTabIndex = index
        }

        if window?.isKeyWindow == true {
            claimWebView(for: tab)
        } else {
            showSnapshot(for: tab)
        }
    }

    private func claimWebView(for tab: BrowserTab) {
        let webView = tab.webView

        if webView.superview?.isDescendant(of: contentContainerView) == true {
            return
        }

        snapshotSubscription = nil
        removeContentViews()

        if let inspector = webView.value(forKey: "_inspector") as? NSObject {
            inspector.perform(Selector(("close")))
        }

        if webView.superview != nil {
            tab.takeSnapshot()
        }

        webView.removeFromSuperview()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "linkHover")
        webView.configuration.userContentController.add(self, name: "linkHover")

        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        contentContainerView.addSubview(webView, positioned: .below, relativeTo: dragHandle)

        let topOffset: CGFloat = findBar.isHidden ? 0 : findBar.frame.height
        let bounds = contentContainerView.bounds
        webView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - topOffset)

        ownsWebView = true
        contentContainerView.addSubview(linkStatusBar, positioned: .above, relativeTo: webView)

        NotificationCenter.default.post(
            name: .webViewOwnershipChanged,
            object: self,
            userInfo: ["tabID": tab.id]
        )
    }

    private func showSnapshot(for tab: BrowserTab) {
        snapshotSubscription = nil
        removeContentViews()
        ownsWebView = false

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.alphaValue = 0.5
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.addSubview(imageView, positioned: .below, relativeTo: dragHandle)

        let topAnchor = findBar.isHidden ? contentContainerView.topAnchor : findBar.bottomAnchor
        webViewTopConstraint = imageView.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            webViewTopConstraint!,
            imageView.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
        ])
        snapshotImageView = imageView

        imageView.image = tab.latestSnapshot

        snapshotSubscription = tab.$latestSnapshot
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak imageView] image in
                imageView?.image = image
            }
    }

    private func removeContentViews() {
        for subview in contentContainerView.subviews where subview !== findBar && subview !== dragHandle && subview !== peekOverlayView && subview !== peekWebView && subview !== linkStatusBar {
            if let webView = subview as? WKWebView {
                webView.configuration.userContentController.removeScriptMessageHandler(forName: "linkHover")
            }
            subview.removeFromSuperview()
        }
        snapshotImageView = nil
        webViewTopConstraint = nil
        ownsWebView = false
        linkStatusBar.hide()
    }

    // MARK: - Window Events

    @objc private func handleWebViewOwnershipChanged(_ notification: Notification) {
        guard let sender = notification.object as? BrowserWindowController, sender !== self,
              let tabID = notification.userInfo?["tabID"] as? UUID,
              tabID == selectedTabID,
              let tab = selectedTab else { return }

        if ownsWebView {
            ownsWebView = false
            showSnapshot(for: tab)
        }
    }

    // MARK: - Navigation

    private func ensureOwnsWebView() {
        if !ownsWebView, let tab = selectedTab {
            claimWebView(for: tab)
        }
    }

    private func navigateToAddress(_ input: String) {
        guard selectedTab != nil else { return }
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        ensureOwnsWebView()

        if let url = urlFromInput(trimmed) {
            selectedTab?.load(url)
        }
    }

    private func urlFromInput(_ input: String) -> URL? {
        if input.hasPrefix("http://") || input.hasPrefix("https://") {
            return URL(string: input)
        }
        if input.contains(".") && !input.contains(" ") {
            return URL(string: "https://\(input)")
        }
        let encoded = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }

    // MARK: - Actions

    @objc func showWebInspector(_ sender: Any?) {
        guard let webView = selectedTab?.webView else { return }
        guard let inspector = webView.value(forKey: "_inspector") as? NSObject else { return }
        inspector.perform(Selector(("show")))
    }

    @objc func reloadPage(_ sender: Any?) {
        ensureOwnsWebView()
        selectedTab?.reload()
    }

    @objc func goBack(_ sender: Any?) {
        ensureOwnsWebView()
        selectedTab?.webView.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        ensureOwnsWebView()
        selectedTab?.webView.goForward()
    }

    @objc func toggleSidebarMode(_ sender: Any?) {
        toggleSidebarAutoHide()
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let space = activeSpace,
              let tab = store.reopenClosedTab(in: space) else { return }
        selectTab(id: tab.id)
    }

    @objc func newTab(_ sender: Any?) {
        commandPaletteNavigatesInPlace = false
        showCommandPalette()
    }

    @objc func focusAddressBar(_ sender: Any?) {
        commandPaletteNavigatesInPlace = true
        showCommandPalette(initialText: selectedTab?.url?.absoluteString)
    }

    private func showCommandPalette(initialText: String? = nil, anchorFrame: NSRect? = nil) {
        guard commandPaletteView == nil else { return }
        let palette = CommandPaletteView()
        palette.delegate = self
        palette.tabStore = store
        palette.activeSpaceID = activeSpaceID
        commandPaletteView = palette

        // Two scrims: the liquid glass sidebar is partially transparent, so we need
        // one behind the sidebar (on splitViewController.view) and one above the
        // content (on contentContainerView).
        let splitScrim = NSView()
        splitScrim.wantsLayer = true
        splitScrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        splitScrim.translatesAutoresizingMaskIntoConstraints = false
        splitViewController.view.addSubview(splitScrim, positioned: .below, relativeTo: splitViewController.view.subviews.first)
        NSLayoutConstraint.activate([
            splitScrim.topAnchor.constraint(equalTo: splitViewController.view.topAnchor),
            splitScrim.bottomAnchor.constraint(equalTo: splitViewController.view.bottomAnchor),
            splitScrim.leadingAnchor.constraint(equalTo: splitViewController.view.leadingAnchor),
            splitScrim.trailingAnchor.constraint(equalTo: splitViewController.view.trailingAnchor),
        ])
        splitScrimView = splitScrim

        if selectedTabID != nil {
            let contentScrim = NSView()
            contentScrim.wantsLayer = true
            contentScrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
            contentScrim.translatesAutoresizingMaskIntoConstraints = false
            contentContainerView.addSubview(contentScrim)
            NSLayoutConstraint.activate([
                contentScrim.topAnchor.constraint(equalTo: contentContainerView.topAnchor),
                contentScrim.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor),
                contentScrim.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
                contentScrim.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
            ])
            contentScrimView = contentScrim
        }

        palette.show(in: window!.contentView!, initialText: initialText, anchorFrame: anchorFrame)
    }

    private func dismissCommandPalette() {
        commandPaletteView?.removeFromSuperview()
        commandPaletteView = nil
        commandPaletteNavigatesInPlace = false
        splitScrimView?.removeFromSuperview()
        splitScrimView = nil
        contentScrimView?.removeFromSuperview()
        contentScrimView = nil
    }

    private func deselectAllTabs() {
        selectedTabID = nil
        activeSpace?.selectedTabID = nil
        activeTabSubscriptions.removeAll()
        dragHandle.isHidden = true
        removeContentViews()
        tabSidebar.fauxAddressBar.displayText = ""
        tabSidebar.fauxAddressBar.isSecure = true
        tabSidebar.backButton.isEnabled = false
        tabSidebar.forwardButton.isEnabled = false
        window?.title = "Detour"
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        // If peek overlay is showing, dismiss it instead of closing the tab
        if peekOverlayView != nil {
            dismissPeekOverlay()
            return
        }

        guard let id = selectedTabID else {
            window?.performClose(sender)
            return
        }

        guard let space = activeSpace else { return }

        // Check if it's a pinned tab
        if let index = space.pinnedTabs.firstIndex(where: { $0.id == id }) {
            closePinnedTab(at: index)
            return
        }

        let tabs = currentTabs
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        closeTab(at: index, wasSelected: true)
    }

    private func closePinnedTab(at index: Int) {
        guard let space = activeSpace else { return }
        let tab = space.pinnedTabs[index]

        if tab.isAtPinnedHome {
            // Fully remove — select next tab
            let allTabs = space.pinnedTabs + space.tabs
            let nextID: UUID?
            if let currentIndex = allTabs.firstIndex(where: { $0.id == tab.id }) {
                if allTabs.count > 1 {
                    nextID = allTabs[currentIndex == allTabs.count - 1 ? currentIndex - 1 : currentIndex + 1].id
                } else {
                    nextID = nil
                }
            } else {
                nextID = nil
            }
            store.closePinnedTab(id: tab.id, in: space)
            if let nextID { selectTab(id: nextID) }
            else { deselectAllTabs() }
        } else {
            // Reset to home — tab stays, select next
            store.closePinnedTab(id: tab.id, in: space)
            // Tab remains pinned, select it if it was selected (it resets to home)
        }
    }

    private func closeTab(at index: Int, wasSelected: Bool) {
        guard let space = activeSpace else { return }
        let tabs = currentTabs
        guard index >= 0, index < tabs.count else { return }

        let nextID: UUID? = tabs.count > 1
            ? tabs[index == tabs.count - 1 ? index - 1 : index + 1].id
            : nil

        store.closeTab(id: tabs[index].id, in: space)

        if wasSelected {
            if let nextID { selectTab(id: nextID) }
            else if let firstPinned = space.pinnedTabs.first { selectTab(id: firstPinned.id) }
            else { deselectAllTabs() }
        }
    }

    // MARK: - Pin/Unpin

    @objc func togglePinTab(_ sender: Any?) {
        guard let tab = selectedTab, let space = activeSpace else { return }
        if tab.isPinned {
            store.unpinTab(id: tab.id, in: space)
            selectTab(id: tab.id)
        } else {
            guard tab.url != nil else { return }
            store.pinTab(id: tab.id, in: space)
            selectTab(id: tab.id)
        }
    }

    // MARK: - Peek Overlay

    private func showPeekOverlay(url: URL, clickPoint: CGPoint? = nil) {
        guard let space = activeSpace else { return }
        dismissPeekOverlay()

        let config = space.makeWebViewConfiguration()
        let peekWebView = WKWebView(frame: .zero, configuration: config)
        peekWebView.navigationDelegate = self
        peekWebView.isInspectable = true

        self.peekWebView = peekWebView

        let overlay = PeekOverlayView(clickPoint: clickPoint)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onClose = { [weak self] in
            self?.dismissPeekOverlay()
        }
        overlay.onExpand = { [weak self] in
            self?.expandPeekToNewTab()
        }

        contentContainerView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: contentContainerView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
        ])

        // Place webview in contentContainerView above the overlay, matching the panel insets
        peekWebView.translatesAutoresizingMaskIntoConstraints = false
        peekWebView.wantsLayer = true
        peekWebView.layer?.cornerRadius = 12
        peekWebView.layer?.masksToBounds = true
        contentContainerView.addSubview(peekWebView, positioned: .above, relativeTo: overlay)

        let topC = peekWebView.topAnchor.constraint(equalTo: contentContainerView.topAnchor, constant: 12)
        let bottomC = peekWebView.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor, constant: -12)
        let leadingC = peekWebView.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor, constant: 64)
        let trailingC = peekWebView.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor, constant: -64)
        NSLayoutConstraint.activate([topC, bottomC, leadingC, trailingC])
        peekWebViewTopConstraint = topC
        peekWebViewBottomConstraint = bottomC
        peekWebViewLeadingConstraint = leadingC
        peekWebViewTrailingConstraint = trailingC

        // Force layout so the overlay and shadowContainer have valid frames,
        // then start the animation. This must happen after constraints are activated.
        contentContainerView.layoutSubtreeIfNeeded()
        overlay.animateOpen()

        // Match the open animation on the webview: scale transform in sync + quick fade
        peekWebView.alphaValue = 0
        if let anim = overlay.webViewOpenAnimation(), let layer = peekWebView.layer {
            layer.transform = CATransform3DIdentity
            layer.add(anim, forKey: "openScale")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            peekWebView.alphaValue = 1
        }

        peekWebView.load(URLRequest(url: url))
        peekOverlayView = overlay
    }

    private func dismissPeekOverlay() {
        guard let overlay = peekOverlayView else { return }
        peekOverlayView = nil
        let peekWebView = self.peekWebView
        self.peekWebView = nil
        overlay.animateClose {
            overlay.removeFromSuperview()
        }
        // Fade out and remove the webview
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            peekWebView?.alphaValue = 0
        }, completionHandler: {
            peekWebView?.removeFromSuperview()
        })
        // Safety net: remove even if animation completion doesn't fire
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak overlay, weak peekWebView] in
            overlay?.removeFromSuperview()
            peekWebView?.removeFromSuperview()
        }
        // Restore first responder to the web view
        if let webView = selectedTab?.webView {
            window?.makeFirstResponder(webView)
        }
    }

    private func expandPeekToNewTab() {
        guard let overlay = peekOverlayView,
              let webView = peekWebView,
              let space = activeSpace else {
            dismissPeekOverlay()
            return
        }

        // Create tab with the existing webview
        let tab = store.addTab(in: space, webView: webView, afterTabID: selectedTabID)

        // Clear peek references so selectTab won't double-dismiss
        peekOverlayView = nil
        self.peekWebView = nil

        // Animate webview constraints from peek insets to full content area
        let topOffset: CGFloat = findBar.isHidden ? 0 : findBar.frame.height

        // Animate corner radius with matching timing
        if let layer = webView.layer {
            let radiusAnim = CABasicAnimation(keyPath: "cornerRadius")
            radiusAnim.fromValue = 12
            radiusAnim.toValue = 0
            radiusAnim.duration = 0.6
            radiusAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.175, 0.885, 0.32, 1.1)
            layer.add(radiusAnim, forKey: "cornerRadius")
            layer.cornerRadius = 0
        }

        // Animate constraints using animator proxy
        NSAnimationContext.runAnimationGroup({ [weak self] context in
            context.duration = 0.6
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.175, 0.885, 0.32, 1.1)
            self?.peekWebViewTopConstraint?.animator().constant = topOffset
            self?.peekWebViewBottomConstraint?.animator().constant = 0
            self?.peekWebViewLeadingConstraint?.animator().constant = 0
            self?.peekWebViewTrailingConstraint?.animator().constant = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            webView.layer?.masksToBounds = false
            // Finalize: select the tab (sets up delegates, ownership, subscriptions)
            self.selectTab(id: tab.id)
        })

        // Fade out peek chrome AFTER starting the constraint animation
        overlay.animateClose {
            overlay.removeFromSuperview()
        }
    }

    // MARK: - Add Space Popover

    private func showAddSpacePopover(relativeTo button: NSButton) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 240, height: 160)

        let vc = AddSpaceViewController()
        vc.onCreate = { [weak self, weak popover] name, emoji, colorHex in
            popover?.close()
            guard let self else { return }
            let space = self.store.addSpace(name: name, emoji: emoji, colorHex: colorHex)
            self.setActiveSpace(id: space.id)
        }
        popover.contentViewController = vc
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showEditSpacePopover(spaceID: UUID, relativeTo button: NSButton) {
        guard let space = store.space(withID: spaceID) else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 240, height: 160)

        let vc = AddSpaceViewController()
        vc.existingSpace = (name: space.name, emoji: space.emoji, colorHex: space.colorHex)
        vc.onCreate = { [weak self, weak popover] name, emoji, colorHex in
            popover?.close()
            guard let self else { return }
            self.store.updateSpace(id: spaceID, name: name, emoji: emoji, colorHex: colorHex)
            if self.activeSpaceID == spaceID {
                self.tabSidebar.tintColor = self.store.space(withID: spaceID)?.color
            }
        }
        popover.contentViewController = vc
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

// MARK: - NSMenuItemValidation

extension BrowserWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(reopenClosedTab(_:)) {
            guard let space = activeSpace else { return false }
            return store.canReopenClosedTab(in: space)
        }
        if menuItem.action == #selector(togglePinTab(_:)) {
            guard let tab = selectedTab else { return false }
            menuItem.title = tab.isPinned ? "Unpin Tab" : "Pin Tab"
            if !tab.isPinned && tab.url == nil { return false }
            return true
        }
        return true
    }
}

// MARK: - NSWindowDelegate

extension BrowserWindowController: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        if let tab = selectedTab {
            claimWebView(for: tab)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if ownsWebView, let tab = selectedTab {
            tab.takeSnapshot()
        }
    }

    func windowWillClose(_ notification: Notification) {
        dismissPeekOverlay()
        if ownsWebView, let tab = selectedTab {
            tab.takeSnapshot()
        }
        store.removeObserver(self)

        if isIncognito, let spaceID = incognitoSpaceID {
            store.removeIncognitoSpace(id: spaceID)
        }
    }
}

// MARK: - NSToolbarDelegate

extension BrowserWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }
}

// MARK: - TabSidebarDelegate

extension BrowserWindowController: TabSidebarDelegate {
    func tabSidebarDidRequestNewTab(_ sidebar: TabSidebarViewController) {
        showCommandPalette()
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didSelectTabAt index: Int) {
        let tabs = currentTabs
        guard index >= 0, index < tabs.count else { return }
        selectTab(id: tabs[index].id)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestCloseTabAt index: Int) {
        let tabs = currentTabs
        guard index >= 0, index < tabs.count else { return }
        closeTab(at: index, wasSelected: tabs[index].id == selectedTabID)
    }

    func tabSidebarDidRequestGoBack(_ sidebar: TabSidebarViewController) {
        ensureOwnsWebView()
        selectedTab?.webView.goBack()
    }

    func tabSidebarDidRequestGoForward(_ sidebar: TabSidebarViewController) {
        ensureOwnsWebView()
        selectedTab?.webView.goForward()
    }

    func tabSidebarDidRequestReload(_ sidebar: TabSidebarViewController) {
        ensureOwnsWebView()
        selectedTab?.reload()
    }

    func tabSidebarDidRequestOpenCommandPalette(_ sidebar: TabSidebarViewController, anchorFrame: NSRect) {
        commandPaletteNavigatesInPlace = true
        showCommandPalette(initialText: selectedTab?.url?.absoluteString, anchorFrame: anchorFrame)
    }

    func tabSidebarDidRequestToggleSidebar(_ sidebar: TabSidebarViewController) {
        toggleSidebarAutoHide()
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didSelectPinnedTabAt index: Int) {
        guard let space = activeSpace, index >= 0, index < space.pinnedTabs.count else { return }
        selectTab(id: space.pinnedTabs[index].id)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestClosePinnedTabAt index: Int) {
        guard let space = activeSpace, index >= 0, index < space.pinnedTabs.count else { return }
        let tab = space.pinnedTabs[index]
        let wasSelected = tab.id == selectedTabID
        if wasSelected {
            closePinnedTab(at: index)
        } else {
            store.closePinnedTab(id: tab.id, in: space)
        }
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didMoveTabFrom sourceIndex: Int, to destinationIndex: Int) {
        guard let space = activeSpace else { return }
        let adjustedDestination = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        store.moveTab(from: sourceIndex, to: adjustedDestination, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didMovePinnedTabFrom sourceIndex: Int, to destinationIndex: Int) {
        guard let space = activeSpace else { return }
        store.movePinnedTab(from: sourceIndex, to: destinationIndex, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didDragTabToPinAt index: Int, destinationIndex: Int) {
        guard let space = activeSpace, index >= 0, index < space.tabs.count else { return }
        let tab = space.tabs[index]
        guard tab.url != nil else { return }
        store.pinTab(id: tab.id, in: space, at: destinationIndex)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didDragPinnedTabToUnpinAt index: Int, destinationIndex: Int) {
        guard let space = activeSpace, index >= 0, index < space.pinnedTabs.count else { return }
        store.unpinTab(id: space.pinnedTabs[index].id, in: space, at: destinationIndex)
    }

    func tabSidebarDidRequestSwitchToSpace(_ sidebar: TabSidebarViewController, spaceID: UUID) {
        setActiveSpace(id: spaceID)
    }

    func tabSidebarDidRequestAddSpace(_ sidebar: TabSidebarViewController, sourceButton: NSButton) {
        showAddSpacePopover(relativeTo: sourceButton)
    }

    func tabSidebarDidRequestEditSpace(_ sidebar: TabSidebarViewController, spaceID: UUID, sourceButton: NSButton) {
        showEditSpacePopover(spaceID: spaceID, relativeTo: sourceButton)
    }

    func tabSidebarDidRequestShowDownloads(_ sidebar: TabSidebarViewController, sourceButton: NSButton) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 300)
        popover.contentViewController = DownloadPopoverViewController()
        popover.show(relativeTo: sourceButton.bounds, of: sourceButton, preferredEdge: .minY)
    }

    func tabSidebarDidRequestDeleteSpace(_ sidebar: TabSidebarViewController, spaceID: UUID) {
        guard let space = store.space(withID: spaceID) else { return }

        if !space.tabs.isEmpty || !space.pinnedTabs.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Cannot Delete Space"
            alert.informativeText = "Close or move all tabs first before deleting this space."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete \"\(space.name)\"?"
        alert.informativeText = "This action cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let wasActive = (activeSpaceID == spaceID)
        store.deleteSpace(id: spaceID)

        if wasActive, let firstSpace = store.spaces.first {
            setActiveSpace(id: firstSpace.id)
        }
    }
}

// MARK: - TabStoreObserver

extension BrowserWindowController: TabStoreObserver {
    func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.insertTab(at: index, tabs: space.tabs)
    }

    func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.removeTab(at: index, tabs: space.tabs)
    }

    func tabStoreDidReorderTabs(in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.setTabs(pinned: space.pinnedTabs, normal: space.tabs)
        if let selectedTabID, let index = currentTabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabSidebar.selectedTabIndex = index
        }
    }

    func tabStoreDidUpdateTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.reloadTab(at: index)
    }

    // Pinned tab observer methods

    func tabStoreDidInsertPinnedTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.insertPinnedTab(at: index, pinnedTabs: space.pinnedTabs)
    }

    func tabStoreDidRemovePinnedTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.removePinnedTab(at: index, pinnedTabs: space.pinnedTabs)
    }

    func tabStoreDidPinTab(_ tab: BrowserTab, fromIndex: Int, toIndex: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.pinTab(fromNormalIndex: fromIndex, toPinnedIndex: toIndex,
                          tabs: space.tabs, pinnedTabs: space.pinnedTabs)
    }

    func tabStoreDidUnpinTab(_ tab: BrowserTab, fromIndex: Int, toIndex: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.unpinTab(fromPinnedIndex: fromIndex, toNormalIndex: toIndex,
                            tabs: space.tabs, pinnedTabs: space.pinnedTabs)
    }

    func tabStoreDidReorderPinnedTabs(in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.pinnedTabs = space.pinnedTabs
        if let selectedTabID, let index = space.pinnedTabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabSidebar.selectedPinnedTabIndex = index
        }
    }

    func tabStoreDidUpdatePinnedTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.reloadPinnedTab(at: index)
    }

    func tabStoreDidResetPinnedTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.reloadPinnedTab(at: index)
    }

    func tabStoreDidUpdateSpaces() {
        if isIncognito {
            // Incognito windows only show their own space
            if let space = activeSpace {
                tabSidebar.updateSpaceButtons(spaces: [space], activeSpaceID: activeSpaceID)
            }
        } else {
            let nonIncognitoSpaces = store.spaces.filter { !$0.isIncognito }
            tabSidebar.updateSpaceButtons(spaces: nonIncognitoSpaces, activeSpaceID: activeSpaceID)
        }

        // If our active space was deleted, switch to the first available space
        if activeSpaceID == nil || store.space(withID: activeSpaceID!) == nil, let firstSpace = store.spaces.first(where: { !$0.isIncognito }) {
            setActiveSpace(id: firstSpace.id)
        }
    }
}

// MARK: - CommandPaletteDelegate

extension BrowserWindowController: CommandPaletteDelegate {
    func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String) {
        let navigateInPlace = commandPaletteNavigatesInPlace
        dismissCommandPalette()

        if navigateInPlace, selectedTab != nil {
            navigateToAddress(input)
        } else {
            guard let space = activeSpace else { return }
            let tab = store.addTab(in: space, afterTabID: selectedTabID)
            selectTab(id: tab.id)
            if let url = urlFromInput(input) {
                tab.load(url)
            }
        }
    }

    func commandPaletteDidDismiss(_ palette: CommandPaletteView) {
        dismissCommandPalette()
    }

    func commandPalette(_ palette: CommandPaletteView, didRequestSwitchToTab tabID: UUID, in spaceID: UUID) {
        dismissCommandPalette()
        if activeSpaceID != spaceID {
            setActiveSpace(id: spaceID)
        }
        selectTab(id: tabID)
    }
}

// MARK: - FindBarDelegate

extension BrowserWindowController: FindBarDelegate {
    func findBar(_ bar: FindBarView, searchFor text: String, backwards: Bool) {
        performFind(text, backwards: backwards)
    }

    func findBarDidDismiss(_ bar: FindBarView) {
        dismissFindBar(nil)
    }
}

// MARK: - WKScriptMessageHandler

extension BrowserWindowController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "linkHover", let urlString = message.body as? String else { return }
        if urlString.isEmpty {
            linkStatusBar.hide()
        } else {
            linkStatusBar.show(url: urlString)
        }
    }
}

// MARK: - WKNavigationDelegate

extension BrowserWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.navigationType == .linkActivated && navigationAction.modifierFlags.contains(.command) {
            if let url = navigationAction.request.url, let space = activeSpace {
                _ = store.addTab(in: space, url: url, afterTabID: selectedTabID)
            }
            return .cancel
        }

        // Shift+click: open link in peek view
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.shift),
           let url = navigationAction.request.url,
           let tab = selectedTab,
           webView === tab.webView,
           peekOverlayView == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let clickPoint = self.window.map {
                    self.contentContainerView.convert($0.mouseLocationOutsideOfEventStream, from: nil)
                }
                self.showPeekOverlay(url: url, clickPoint: clickPoint)
            }
            return .cancel
        }

        // When navigating forward into an error page, re-attempt the original URL instead
        if navigationAction.navigationType == .backForward,
           let url = navigationAction.request.url,
           let originalURL = ErrorPage.originalURL(from: url) {
            DispatchQueue.main.async { [weak self] in
                self?.selectedTab?.load(originalURL)
            }
            return .cancel
        }

        // Open non-HTTP(S) URLs (App Store, mailto, etc.) externally
        if let url = navigationAction.request.url,
           let scheme = url.scheme,
           scheme != "http", scheme != "https",
           scheme != "about", scheme != ErrorPage.scheme {
            NSWorkspace.shared.open(url)
            return .cancel
        }

        if navigationAction.shouldPerformDownload {
            return .download
        }

        // Peek mode: intercept cross-host navigation on pinned tabs
        // Only intercept on the pinned tab's own webView, not the peek webView
        if let tab = selectedTab, tab.isPinned,
           webView === tab.webView,
           peekOverlayView == nil,
           let url = navigationAction.request.url,
           let pinnedHost = tab.pinnedURL?.host,
           let targetHost = url.host,
           targetHost != pinnedHost,
           navigationAction.navigationType == .linkActivated {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let clickPoint = self.window.map {
                    self.contentContainerView.convert($0.mouseLocationOutsideOfEventStream, from: nil)
                }
                self.showPeekOverlay(url: url, clickPoint: clickPoint)
            }
            return .cancel
        }

        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !navigationResponse.canShowMIMEType {
            return .download
        }
        if let response = navigationResponse.response as? HTTPURLResponse,
           let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        let sourceURL = navigationResponse.response.url
        download.delegate = DownloadManager.shared
        let item = DownloadManager.shared.handleNewDownload(download, sourceURL: sourceURL)
        _ = item // suppress unused warning
        triggerDownloadAnimation()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        let sourceURL = navigationAction.request.url
        download.delegate = DownloadManager.shared
        let item = DownloadManager.shared.handleNewDownload(download, sourceURL: sourceURL)
        _ = item
        triggerDownloadAnimation()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView.url?.scheme == ErrorPage.scheme { return }
        selectedTab?.didCommitNavigation()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // WebKitErrorFrameLoadInterruptedByPolicyChange (102) fires when a navigation
        // becomes a download — not a real failure, so don't show an error page.
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        selectedTab?.didFailProvisionalNavigation(error: error)
    }

    private func triggerDownloadAnimation() {
        guard let window = self.window else { return }
        let contentBounds = contentContainerView.bounds
        guard contentBounds.width > 0, contentBounds.height > 0 else { return }

        let sourcePoint = contentContainerView.convert(
            NSPoint(x: contentBounds.midX, y: contentBounds.midY), to: nil
        )
        guard sourcePoint.x.isFinite, sourcePoint.y.isFinite else { return }

        let destPoint: NSPoint
        if !sidebarItem.isCollapsed {
            let buttonFrame = tabSidebar.downloadButton.convert(tabSidebar.downloadButton.bounds, to: nil)
            guard buttonFrame.width > 0 else { return }
            destPoint = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        } else {
            destPoint = NSPoint(x: 20, y: 20)
        }

        DownloadAnimation.animate(in: window, from: sourcePoint, to: destPoint)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let window = self.window else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Log in to \(challenge.protectionSpace.host)"
        if let realm = challenge.protectionSpace.realm, !realm.isEmpty {
            alert.informativeText = realm
        }
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")

        let usernameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        usernameField.placeholderString = "Username"

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        passwordField.placeholderString = "Password"

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 56))
        usernameField.frame = NSRect(x: 0, y: 32, width: 200, height: 24)
        passwordField.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        container.addSubview(usernameField)
        container.addSubview(passwordField)
        alert.accessoryView = container

        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                let credential = URLCredential(user: usernameField.stringValue,
                                               password: passwordField.stringValue,
                                               persistence: .forSession)
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.rejectProtectionSpace, nil)
            }
        }
    }
}

// MARK: - DownloadManagerObserver

extension BrowserWindowController: DownloadManagerObserver {
    func downloadManagerDidAddItem(_ item: DownloadItem) {
        updateDownloadBadge()
    }

    func downloadManagerDidUpdateItem(_ item: DownloadItem) {
        updateDownloadBadge()
    }

    func downloadManagerDidRemoveItem(_ item: DownloadItem) {
        updateDownloadBadge()
    }

    private func updateDownloadBadge() {
        tabSidebar.updateDownloadBadge(hasActive: DownloadManager.shared.hasActiveDownloads)
    }
}

