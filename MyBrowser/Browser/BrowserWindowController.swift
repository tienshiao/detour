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

    private var selectedTabID: UUID?
    private var activeTabSubscriptions = Set<AnyCancellable>()
    private var snapshotImageView: NSImageView?
    private var ownsWebView = false
    private var snapshotSubscription: AnyCancellable?

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

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: tabSidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 350
        sidebarItem.canCollapse = true
        splitViewController.addSplitViewItem(sidebarItem)

        let contentVC = NSViewController()
        contentVC.view = contentContainerView
        contentContainerView.wantsLayer = true
        let contentItem = NSSplitViewItem(viewController: contentVC)
        splitViewController.addSplitViewItem(contentItem)

        window?.contentViewController = splitViewController
    }

    // MARK: - Tab Selection & WebView Ownership

    func selectTab(id: UUID) {
        guard store.tab(withID: id) != nil else { return }

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
        snapshotSubscription = nil
        removeContentViews()

        let webView = tab.webView

        // Take a snapshot while the webview is still attached to its current window,
        // so the previous owner has a fresh image to display immediately.
        if webView.superview != nil {
            tab.takeSnapshot()
        }

        webView.removeFromSuperview()
        webView.navigationDelegate = self
        webView.uiDelegate = self

        webView.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: contentContainerView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
        ])

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
        contentContainerView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentContainerView.topAnchor),
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
        for subview in contentContainerView.subviews {
            subview.removeFromSuperview()
        }
        snapshotImageView = nil
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

    @objc func newTab(_ sender: Any?) {
        let tab = store.addTab(afterTabID: selectedTabID)
        selectTab(id: tab.id)
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
        } else if let first = store.tabs.first {
            selectTab(id: first.id)
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
        newTab(nil)
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
            } else if let first = store.tabs.first {
                selectTab(id: first.id)
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
