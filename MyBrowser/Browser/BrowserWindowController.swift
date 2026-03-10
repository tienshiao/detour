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

    private var selectedTabID: UUID?
    private var activeTabSubscriptions = Set<AnyCancellable>()
    private var snapshotImageView: NSImageView?
    private var ownsWebView = false
    private var snapshotSubscription: AnyCancellable?

    private let findBar = FindBarView()
    private let dragHandle = WindowDragView()
    private var findBarTopConstraint: NSLayoutConstraint?
    private var webViewTopConstraint: NSLayoutConstraint?
    private var findMatchCount = 0
    private var findMatchIndex = 0
    private var lastFindQuery = ""

    private var commandPaletteView: CommandPaletteView?
    private var splitScrimView: NSView?

    private var store: TabStore { TabStore.shared }

    private var selectedTab: BrowserTab? {
        guard let selectedTabID else { return nil }
        return store.tab(withID: selectedTabID)
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.setFrameAutosaveName("BrowserWindow")
        window.minSize = NSSize(width: 600, height: 400)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true

        self.init(window: window)

        setupToolbar()
        setupSplitView()
        setupDragHandle()
        setupFindBar()

        window.delegate = self

        store.addObserver(self)
        tabSidebar.tabs = store.tabs

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWebViewOwnershipChanged(_:)),
            name: .webViewOwnershipChanged,
            object: nil
        )
    }

    deinit {
        store.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
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
        // Thin invisible view on the left edge for hover detection
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

        // Tracking area on sidebar view for exit detection
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
            // Switch to auto-hide: collapse the sidebar
            if !sidebarItem.isCollapsed {
                splitViewController.toggleSidebar(nil)
            }
        } else {
            // Switch to pinned: show the sidebar
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

        for subview in contentContainerView.subviews where subview !== findBar && subview !== dragHandle {
            if subview is WKWebView {
                // WKWebView uses autoresizing mask — adjust frame directly
                subview.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - topOffset)
            } else if subview is NSImageView {
                // Snapshot image views use Auto Layout
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
        guard store.tab(withID: id) != nil else { return }

        dismissCommandPalette()

        // Clean up previous tab's view
        if let previousTab = selectedTab {
            if ownsWebView {
                previousTab.takeSnapshot()
            }
        }
        removeContentViews()

        selectedTabID = id
        store.selectedTabID = id
        activeTabSubscriptions.removeAll()

        let tab = store.tab(withID: id)!

        // Subscribe to active tab's properties for UI updates
        tab.$url
            .receive(on: RunLoop.main)
            .sink { [weak self] url in
                self?.tabSidebar.addressField.stringValue = url?.absoluteString ?? ""
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

        // Update sidebar selection
        if let index = store.index(of: id) {
            tabSidebar.selectedTabIndex = index
        }

        // Show live webview or snapshot
        if window?.isKeyWindow == true {
            claimWebView(for: tab)
        } else {
            showSnapshot(for: tab)
        }
    }

    private func claimWebView(for tab: BrowserTab) {
        let webView = tab.webView

        // Already owned by this window — nothing to do.
        if webView.superview?.isDescendant(of: contentContainerView) == true {
            return
        }

        snapshotSubscription = nil
        removeContentViews()

        // Close the inspector before transfer so the webview returns
        // to full size for snapshotting and avoids rendering issues in the new window.
        if let inspector = webView.value(forKey: "_inspector") as? NSObject {
            inspector.perform(Selector(("close")))
        }

        // Take a snapshot while the webview is still attached to its current window,
        // so the previous owner has a fresh image to display immediately.
        if webView.superview != nil {
            tab.takeSnapshot()
        }

        webView.removeFromSuperview()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        contentContainerView.addSubview(webView, positioned: .below, relativeTo: dragHandle)

        let topOffset: CGFloat = findBar.isHidden ? 0 : findBar.frame.height
        let bounds = contentContainerView.bounds
        webView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - topOffset)

        ownsWebView = true

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

        // Show current snapshot immediately (may be stale or nil)
        imageView.image = tab.latestSnapshot

        // Always subscribe so we pick up the fresh snapshot when the async
        // takeSnapshot() call completes after ownership transfer.
        snapshotSubscription = tab.$latestSnapshot
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak imageView] image in
                imageView?.image = image
            }
    }

    private func removeContentViews() {
        for subview in contentContainerView.subviews where subview !== findBar && subview !== dragHandle {
            subview.removeFromSuperview()
        }
        snapshotImageView = nil
        webViewTopConstraint = nil
        ownsWebView = false
    }

    // MARK: - Window Events

    @objc private func handleWebViewOwnershipChanged(_ notification: Notification) {
        guard let sender = notification.object as? BrowserWindowController, sender !== self,
              let tabID = notification.userInfo?["tabID"] as? UUID,
              tabID == selectedTabID,
              let tab = selectedTab else { return }

        // Another window took our webview — switch to snapshot
        if ownsWebView {
            ownsWebView = false
            showSnapshot(for: tab)
        }
    }

    // MARK: - Navigation

    private func navigateToAddress(_ input: String) {
        guard selectedTab != nil else { return }
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // If we don't own the webview, claim it first
        if !ownsWebView, let tab = selectedTab {
            claimWebView(for: tab)
        }

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

    @objc func goBack(_ sender: Any?) {
        if !ownsWebView, let tab = selectedTab { claimWebView(for: tab) }
        selectedTab?.webView.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        if !ownsWebView, let tab = selectedTab { claimWebView(for: tab) }
        selectedTab?.webView.goForward()
    }

    @objc func toggleSidebarMode(_ sender: Any?) {
        toggleSidebarAutoHide()
    }

    @objc func newTab(_ sender: Any?) {
        showCommandPalette()
    }

    private func showCommandPalette() {
        guard commandPaletteView == nil else { return }
        let palette = CommandPaletteView()
        palette.delegate = self
        commandPaletteView = palette

        // Add a scrim behind the sidebar and content so it shows through the translucent sidebar
        let scrim = NSView()
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        scrim.translatesAutoresizingMaskIntoConstraints = false
        splitViewController.view.addSubview(scrim, positioned: .below, relativeTo: splitViewController.view.subviews.first)
        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: splitViewController.view.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: splitViewController.view.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: splitViewController.view.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: splitViewController.view.trailingAnchor),
        ])
        splitScrimView = scrim

        palette.show(in: contentContainerView)
    }

    private func dismissCommandPalette() {
        commandPaletteView?.removeFromSuperview()
        commandPaletteView = nil
        splitScrimView?.removeFromSuperview()
        splitScrimView = nil
    }

    private func deselectAllTabs() {
        selectedTabID = nil
        store.selectedTabID = nil
        activeTabSubscriptions.removeAll()
        removeContentViews()
        tabSidebar.addressField.stringValue = ""
        tabSidebar.backButton.isEnabled = false
        tabSidebar.forwardButton.isEnabled = false
        window?.title = "MyBrowser"
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        guard let id = selectedTabID else { return }
        let tabs = store.tabs
        guard let index = store.index(of: id) else { return }

        // Pre-compute what we'll select next
        let nextID: UUID?
        if tabs.count > 1 {
            let newIndex = min(index, tabs.count - 2)
            let candidate = tabs[newIndex == index ? min(index + 1, tabs.count - 1) : newIndex]
            nextID = candidate.id
        } else {
            nextID = nil // TabStore will auto-create a blank tab
        }

        store.closeTab(id: id)

        if let nextID {
            selectTab(id: nextID)
        } else {
            deselectAllTabs()
        }
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
        if ownsWebView, let tab = selectedTab {
            tab.takeSnapshot()
        }
        store.removeObserver(self)
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
        let tabs = store.tabs
        guard index >= 0, index < tabs.count else { return }
        selectTab(id: tabs[index].id)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestCloseTabAt index: Int) {
        let tabs = store.tabs
        guard index >= 0, index < tabs.count else { return }
        let id = tabs[index].id

        // Pre-compute next selection
        let nextID: UUID?
        if tabs.count > 1 {
            let newIndex = index >= tabs.count - 1 ? index - 1 : index + 1
            nextID = tabs[newIndex].id
        } else {
            nextID = nil
        }

        let wasSelected = (id == selectedTabID)
        store.closeTab(id: id)

        if wasSelected {
            if let nextID {
                selectTab(id: nextID)
            } else {
                deselectAllTabs()
            }
        }
    }

    func tabSidebarDidRequestGoBack(_ sidebar: TabSidebarViewController) {
        if !ownsWebView, let tab = selectedTab { claimWebView(for: tab) }
        selectedTab?.webView.goBack()
    }

    func tabSidebarDidRequestGoForward(_ sidebar: TabSidebarViewController) {
        if !ownsWebView, let tab = selectedTab { claimWebView(for: tab) }
        selectedTab?.webView.goForward()
    }

    func tabSidebarDidRequestReload(_ sidebar: TabSidebarViewController) {
        if !ownsWebView, let tab = selectedTab { claimWebView(for: tab) }
        selectedTab?.webView.reload()
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didSubmitAddressInput input: String) {
        navigateToAddress(input)
    }

    func tabSidebarDidRequestToggleSidebar(_ sidebar: TabSidebarViewController) {
        toggleSidebarAutoHide()
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didMoveTabFrom sourceIndex: Int, to destinationIndex: Int) {
        let adjustedDestination = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        store.moveTab(from: sourceIndex, to: adjustedDestination)
    }
}

// MARK: - TabStoreObserver

extension BrowserWindowController: TabStoreObserver {
    func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int) {
        tabSidebar.tabs = store.tabs
    }

    func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int) {
        tabSidebar.tabs = store.tabs
    }

    func tabStoreDidReorderTabs() {
        tabSidebar.tabs = store.tabs
        if let selectedTabID, let index = store.index(of: selectedTabID) {
            tabSidebar.selectedTabIndex = index
        }
    }

    func tabStoreDidUpdateTab(_ tab: BrowserTab, at index: Int) {
        tabSidebar.reloadTab(at: index)
    }
}

// MARK: - CommandPaletteDelegate

extension BrowserWindowController: CommandPaletteDelegate {
    func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String) {
        dismissCommandPalette()
        let tab = store.addTab(afterTabID: selectedTabID)
        selectTab(id: tab.id)
        if let url = urlFromInput(input) {
            tab.load(url)
        }
    }

    func commandPaletteDidDismiss(_ palette: CommandPaletteView) {
        dismissCommandPalette()
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

// MARK: - WKNavigationDelegate

extension BrowserWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.navigationType == .linkActivated && navigationAction.modifierFlags.contains(.command) {
            if let url = navigationAction.request.url {
                let tab = store.addTab(url: url, afterTabID: selectedTabID)
                selectTab(id: tab.id)
            }
            return .cancel
        }
        return .allow
    }
}

// MARK: - WKUIDelegate

extension BrowserWindowController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            let tab = store.addTab(url: url, afterTabID: selectedTabID)
            selectTab(id: tab.id)
        }
        return nil
    }
}
