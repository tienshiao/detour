import AppKit
import WebKit
import Combine

extension Notification.Name {
    static let webViewOwnershipChanged = Notification.Name("webViewOwnershipChanged")
}

class BrowserWindowController: NSWindowController {
    private let splitViewController = NSSplitViewController()
    let tabSidebar = TabSidebarViewController()
    let contentContainerView = NSView()
    var sidebarItem: NSSplitViewItem!
    private var contentItem: NSSplitViewItem!
    private var sidebarCollapseObservation: NSKeyValueObservation?
    private var sidebarAutoHides = false
    private var sidebarOpenedByHover = false
    private var autoHideWorkItem: DispatchWorkItem?

    var selectedTabID: UUID?
    private var activeTabSubscriptions = Set<AnyCancellable>()
    private var snapshotImageView: NSImageView?
    private var ownsWebView = false
    private var localSnapshot: NSImage?

    private let findBar = FindBarView()
    private let dragHandle = WindowDragView()
    private let linkStatusBar = LinkStatusBar()
    private let emptyStateLabel: NSTextField = {
        let label = NSTextField(labelWithString: "A rare moment of tab peace.")
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()
    let toastManager = ToastManager()
    private var webViewTopConstraint: NSLayoutConstraint?
    private var findMatchCount = 0
    private var findMatchIndex = 0
    private var lastFindQuery = ""

    private var commandPaletteView: CommandPaletteView?
    var commandPaletteNavigatesInPlace = false
    private var splitScrimView: NSView?
    private var contentScrimView: NSView?

    private(set) var isIncognito = false
    private var incognitoSpaceID: UUID?

    enum ContextMenuLinkAction {
        case none, openInNewTab, openInNewWindow
    }
    var contextMenuLinkAction: ContextMenuLinkAction = .none

    var peekOverlayView: PeekOverlayView?
    private var peekWebView: WKWebView?
    private var peekWebViewTopConstraint: NSLayoutConstraint?
    private var peekWebViewBottomConstraint: NSLayoutConstraint?
    private var peekWebViewLeadingConstraint: NSLayoutConstraint?
    private var peekWebViewTrailingConstraint: NSLayoutConstraint?

    var store: TabStore { TabStore.shared }

    // MARK: - Per-window space state

    var activeSpaceID: UUID?

    var activeSpace: Space? {
        guard let activeSpaceID else { return nil }
        return store.space(withID: activeSpaceID)
    }

    var currentTabs: [BrowserTab] {
        activeSpace?.tabs ?? []
    }

    var selectedTab: BrowserTab? {
        guard let selectedTabID else { return nil }
        return activeSpace?.pinnedTabs.first { $0.id == selectedTabID }
            ?? currentTabs.first { $0.id == selectedTabID }
    }

    private static let frameAutosaveName = "BrowserWindow"

    convenience init(incognito: Bool) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultWidth = min(screenFrame.width * 0.8, 1600)
        let defaultHeight = min(screenFrame.height * 0.85, 1100)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultWidth, height: defaultHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
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

        if let parentWindow = NSApp.keyWindow,
           parentWindow.windowController is BrowserWindowController {
            var frame = parentWindow.frame
            let cascadeOffset: CGFloat = 22
            frame.origin.x += cascadeOffset
            frame.origin.y -= cascadeOffset
            window.setFrame(frame, display: false)
        } else if !incognito {
            window.setFrameAutosaveName(BrowserWindowController.frameAutosaveName)
        }

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
            tabSidebar.pinnedFolders = activeSpace?.pinnedFolders ?? []
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

        tabSidebar.applyState(pinnedTabs: space.pinnedTabs, pinnedFolders: space.pinnedFolders, tabs: space.tabs)
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
        tabSidebar.fauxAddressBar.onCopyURL = { [weak self] in
            self?.copyCurrentURL(nil)
        }

        sidebarItem = NSSplitViewItem(sidebarWithViewController: tabSidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 350
        sidebarItem.canCollapse = true
        splitViewController.addSplitViewItem(sidebarItem)

        let contentVC = NSViewController()
        contentVC.view = contentContainerView
        contentContainerView.wantsLayer = true
        contentContainerView.addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: contentContainerView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: contentContainerView.centerYAnchor),
        ])
        toastManager.parentView = contentContainerView
        contentItem = NSSplitViewItem(viewController: contentVC)
        splitViewController.addSplitViewItem(contentItem)

        splitViewController.splitView.autosaveName = "BrowserSplitView"

        sidebarCollapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
            guard let self, let collapsed = change.newValue else { return }
            if collapsed {
                self.sidebarOpenedByHover = false
                self.setTrafficLightsHidden(true, animated: false)
            } else {
                self.setTrafficLightsHidden(false, animated: true)
            }
        }

        splitViewController.view.frame = window?.contentView?.bounds ?? .zero
        splitViewController.view.autoresizingMask = [.width, .height]
        window?.contentView?.addSubview(splitViewController.view)

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

    func toggleSidebarAutoHide() {
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
        contentContainerView.addSubview(findBar)

        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: contentContainerView.topAnchor, constant: 12),
            findBar.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor, constant: 12),
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
        findBar.searchField.stringValue = ""
        findBar.updateResultLabel("")
        lastFindQuery = ""
        findMatchCount = 0
        findMatchIndex = 0
        window?.makeFirstResponder(selectedTab?.webView)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            findBar.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.findBar.isHidden = true
        })
    }

    func performFind(_ text: String, backwards: Bool) {
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


    // MARK: - Tab Selection & WebView Ownership

    func selectTab(id: UUID) {
        let isPinnedTab = activeSpace?.pinnedTabs.contains(where: { $0.id == id }) ?? false
        let isNormalTab = currentTabs.contains(where: { $0.id == id })
        guard isPinnedTab || isNormalTab else { return }

        dismissCommandPalette()
        dismissPeekOverlay()

        if let previousTab = selectedTab {
            previousTab.lastDeselectedAt = Date()
            if ownsWebView {
                previousTab.takeSnapshot { [weak self] image in
                    self?.localSnapshot = image
                }
            }
        }
        removeContentViews()
        localSnapshot = nil

        selectedTabID = id
        activeSpace?.selectedTabID = id
        activeTabSubscriptions.removeAll()
        dragHandle.isHidden = false

        guard let tab = selectedTab else { return }
        tab.lastDeselectedAt = nil
        if tab.isSleeping { tab.wake() }

        tab.$url
            .receive(on: RunLoop.main)
            .sink { [weak self] url in
                self?.tabSidebar.fauxAddressBar.displayText = tab.displayHost
                self?.tabSidebar.fauxAddressBar.isSecure = url?.scheme == "https" || url == nil
            }
            .store(in: &activeTabSubscriptions)

        tab.$canGoBack
            .receive(on: RunLoop.main)
            .sink { [weak self] canGoBack in
                let canCloseToParent = !canGoBack && self?.parentTab(for: tab) != nil
                self?.tabSidebar.backButton.isEnabled = canGoBack || canCloseToParent
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

        if let space = activeSpace {
            tabSidebar.applyState(pinnedTabs: space.pinnedTabs, pinnedFolders: space.pinnedFolders,
                                  tabs: currentTabs, selectedTabID: id)
        }

        if let index = activeSpace?.pinnedTabs.firstIndex(where: { $0.id == id }) {
            tabSidebar.selectedPinnedTabIndex = index
        } else if let index = currentTabs.firstIndex(where: { $0.id == id }) {
            tabSidebar.selectedTabIndex = index
        }

        if window?.isKeyWindow == true || tab.webView?.superview == nil {
            claimWebView(for: tab)
        } else {
            showSnapshot(for: tab)
        }
    }

    private func claimWebView(for tab: BrowserTab) {
        guard let webView = tab.webView else { return }

        if webView.superview?.isDescendant(of: contentContainerView) == true {
            return
        }

        removeContentViews()

        if let inspector = webView.value(forKey: "_inspector") as? NSObject {
            inspector.perform(NSSelectorFromString("close"))
        }

        // Snapshot the webView at its current size (the old window's size) before stealing it.
        var priorSnapshot: NSImage?
        if let bitmap = webView.bitmapImageRepForCachingDisplay(in: webView.bounds) {
            webView.cacheDisplay(in: webView.bounds, to: bitmap)
            let image = NSImage(size: webView.bounds.size)
            image.addRepresentation(bitmap)
            priorSnapshot = image
        }
        let tabID = tab.id

        webView.removeFromSuperview()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "linkHover")
        webView.configuration.userContentController.add(self, name: "linkHover")

        // Use frame-based layout (not constraints) for WKWebView — Auto Layout breaks Web Inspector.
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        contentContainerView.addSubview(webView, positioned: .below, relativeTo: dragHandle)

        let bounds = contentContainerView.bounds
        webView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)

        ownsWebView = true
        contentContainerView.addSubview(linkStatusBar, positioned: .above, relativeTo: webView)

        var userInfo: [String: Any] = ["tabID": tabID]
        if let priorSnapshot {
            userInfo["snapshot"] = priorSnapshot
        }
        NotificationCenter.default.post(
            name: .webViewOwnershipChanged,
            object: self,
            userInfo: userInfo
        )
    }

    private func showSnapshot(for tab: BrowserTab) {
        removeContentViews()
        ownsWebView = false

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.alphaValue = 0.5
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.addSubview(imageView, positioned: .below, relativeTo: dragHandle)

        webViewTopConstraint = imageView.topAnchor.constraint(equalTo: contentContainerView.topAnchor)
        NSLayoutConstraint.activate([
            webViewTopConstraint!,
            imageView.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
        ])
        snapshotImageView = imageView

        imageView.image = localSnapshot
    }

    private func removeContentViews() {
        emptyStateLabel.isHidden = true
        for subview in contentContainerView.subviews where subview !== findBar && subview !== dragHandle && subview !== peekOverlayView && subview !== peekWebView && subview !== linkStatusBar && subview !== emptyStateLabel {
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
            if let image = notification.userInfo?["snapshot"] as? NSImage {
                localSnapshot = image
            }
            showSnapshot(for: tab)
        }
    }

    // MARK: - Navigation

    func ensureOwnsWebView() {
        if !ownsWebView, let tab = selectedTab {
            claimWebView(for: tab)
        }
    }

    func navigateToAddress(_ input: String) {
        guard selectedTab != nil else { return }
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        ensureOwnsWebView()

        if let url = urlFromInput(trimmed) {
            selectedTab?.load(url)
        }
    }

    func urlFromInput(_ input: String) -> URL? {
        if input.hasPrefix("http://") || input.hasPrefix("https://") {
            return URL(string: input)
        }
        if input.contains(".") && !input.contains(" ") {
            return URL(string: "https://\(input)")
        }
        let engine = activeSpace?.profile?.searchEngine ?? .google
        return engine.searchURL(for: input)
    }

    // MARK: - Actions

    @objc func showWebInspector(_ sender: Any?) {
        guard let webView = selectedTab?.webView else { return }
        guard let inspector = webView.value(forKey: "_inspector") as? NSObject else { return }
        inspector.perform(Selector(("show")))
    }

    @objc func copyCurrentURL(_ sender: Any?) {
        guard let urlString = selectedTab?.url?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
        toastManager.show(message: "URL copied")
    }

    @objc func reloadPage(_ sender: Any?) {
        ensureOwnsWebView()
        selectedTab?.reload()
    }

    @objc func goBack(_ sender: Any?) {
        navigateBackOrCloseChildTab()
    }

    private func parentTab(for tab: BrowserTab) -> BrowserTab? {
        guard let parentID = tab.parentID else { return nil }
        return currentTabs.first { $0.id == parentID }
            ?? activeSpace?.pinnedTabs.first { $0.id == parentID }
    }

    func navigateBackOrCloseChildTab() {
        guard let tab = selectedTab else { return }
        if tab.canGoBack {
            ensureOwnsWebView()
            tab.webView?.goBack()
        } else if let parent = parentTab(for: tab) {
            guard let space = activeSpace else { return }
            store.closeTab(id: tab.id, in: space)
            selectTab(id: parent.id)
        }
    }

    @objc func goForward(_ sender: Any?) {
        ensureOwnsWebView()
        selectedTab?.webView?.goForward()
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

    func showCommandPalette(initialText: String? = nil, anchorFrame: NSRect? = nil) {
        guard commandPaletteView == nil else { return }
        let palette = CommandPaletteView()
        palette.delegate = self
        palette.tabStore = store
        palette.activeSpaceID = activeSpaceID
        palette.profile = activeSpace?.profile
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

    func dismissCommandPalette() {
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
        let hasTabs = !(activeSpace?.tabs.isEmpty ?? true) || !(activeSpace?.pinnedTabs.isEmpty ?? true)
        emptyStateLabel.stringValue = hasTabs ? "Where to next?" : "A rare moment of tab peace."
        emptyStateLabel.isHidden = false
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

    func closePinnedTab(at index: Int) {
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

    func closeTab(at index: Int, wasSelected: Bool) {
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

    func showPeekOverlay(url: URL, clickPoint: CGPoint? = nil) {
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
        let tab = store.addTab(in: space, webView: webView, parentID: selectedTabID)

        // Clear peek references so selectTab won't double-dismiss
        peekOverlayView = nil
        self.peekWebView = nil

        // Animate webview constraints from peek insets to full content area

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
            self?.peekWebViewTopConstraint?.animator().constant = 0
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

    func showAddSpacePopover(relativeTo button: NSButton) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 240, height: 210)

        let vc = AddSpaceViewController()
        vc.onCreate = { [weak self, weak popover] name, emoji, colorHex, profileID in
            popover?.close()
            guard let self else { return }
            let space = self.store.addSpace(name: name, emoji: emoji, colorHex: colorHex, profileID: profileID)
            self.setActiveSpace(id: space.id)
        }
        popover.contentViewController = vc
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func showEditSpacePopover(spaceID: UUID, relativeTo button: NSButton) {
        guard let space = store.space(withID: spaceID) else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 240, height: 210)

        let vc = AddSpaceViewController()
        vc.existingSpace = (name: space.name, emoji: space.emoji, colorHex: space.colorHex, profileID: space.profileID)
        vc.onCreate = { [weak self, weak popover] name, emoji, colorHex, profileID in
            popover?.close()
            guard let self else { return }
            self.store.updateSpace(id: spaceID, name: name, emoji: emoji, colorHex: colorHex, profileID: profileID)
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

    func windowWillClose(_ notification: Notification) {
        dismissPeekOverlay()
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

// MARK: - CommandPaletteDelegate

extension BrowserWindowController: CommandPaletteDelegate {
    func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String) {
        let navigateInPlace = commandPaletteNavigatesInPlace
        dismissCommandPalette()

        if navigateInPlace, selectedTab != nil {
            navigateToAddress(input)
        } else {
            guard let space = activeSpace else { return }
            let tab = store.addTab(in: space)
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

