import AppKit
import WebKit
import Combine

class BrowserWindowController: NSWindowController {
    private let splitViewController = NSSplitViewController()
    private let tabSidebar = TabSidebarViewController()
    private let contentContainerView = NSView()

    private var tabs: [BrowserTab] = []
    private var activeTab: BrowserTab?
    private var subscriptions: [UUID: Set<AnyCancellable>] = [:]

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
        addNewTab(url: URL(string: "https://www.apple.com")!)
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

    // MARK: - Tab Management

    func addNewTab(url: URL? = nil, afterActiveTab: Bool = false) {
        let tab = BrowserTab()
        tab.webView.navigationDelegate = self
        tab.webView.uiDelegate = self

        let insertionIndex: Int
        if afterActiveTab, let active = activeTab, let activeIndex = tabs.firstIndex(where: { $0.id == active.id }) {
            insertionIndex = activeIndex + 1
            tabs.insert(tab, at: insertionIndex)
        } else {
            tabs.append(tab)
            insertionIndex = tabs.count - 1
        }

        var cancellables = Set<AnyCancellable>()

        tab.$title
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let index = self.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                self.tabSidebar.reloadTab(at: index)
                if self.activeTab?.id == tab.id {
                    self.window?.title = tab.title
                }
            }
            .store(in: &cancellables)

        tab.$url
            .receive(on: RunLoop.main)
            .sink { [weak self] url in
                guard let self, self.activeTab?.id == tab.id else { return }
                self.tabSidebar.addressField.stringValue = url?.absoluteString ?? ""
            }
            .store(in: &cancellables)

        tab.$canGoBack
            .receive(on: RunLoop.main)
            .sink { [weak self] canGoBack in
                guard let self, self.activeTab?.id == tab.id else { return }
                self.tabSidebar.backButton.isEnabled = canGoBack
            }
            .store(in: &cancellables)

        tab.$canGoForward
            .receive(on: RunLoop.main)
            .sink { [weak self] canGoForward in
                guard let self, self.activeTab?.id == tab.id else { return }
                self.tabSidebar.forwardButton.isEnabled = canGoForward
            }
            .store(in: &cancellables)

        subscriptions[tab.id] = cancellables
        tabSidebar.tabs = tabs
        selectTab(at: insertionIndex)

        if let url {
            tab.load(url)
        }
    }

    private func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }

        activeTab?.webView.removeFromSuperview()

        let tab = tabs[index]
        activeTab = tab

        let webView = tab.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: contentContainerView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
        ])

        tabSidebar.addressField.stringValue = tab.url?.absoluteString ?? ""
        tabSidebar.backButton.isEnabled = tab.canGoBack
        tabSidebar.forwardButton.isEnabled = tab.canGoForward
        window?.title = tab.title
        tabSidebar.selectedTabIndex = index
    }

    private func closeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }

        let tab = tabs[index]
        subscriptions.removeValue(forKey: tab.id)
        tab.webView.removeFromSuperview()
        tabs.remove(at: index)
        tabSidebar.tabs = tabs

        if tabs.isEmpty {
            addNewTab()
        } else if activeTab?.id == tab.id {
            let newIndex = min(index, tabs.count - 1)
            selectTab(at: newIndex)
        }
    }

    // MARK: - Navigation

    private func navigateToAddress(_ input: String) {
        guard let tab = activeTab else { return }
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if let url = urlFromInput(trimmed) {
            tab.load(url)
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
        addNewTab()
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        guard let active = activeTab, let index = tabs.firstIndex(where: { $0.id == active.id }) else { return }
        closeTab(at: index)
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
        addNewTab()
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didSelectTabAt index: Int) {
        selectTab(at: index)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestCloseTabAt index: Int) {
        closeTab(at: index)
    }

    func tabSidebarDidRequestGoBack(_ sidebar: TabSidebarViewController) {
        activeTab?.webView.goBack()
    }

    func tabSidebarDidRequestGoForward(_ sidebar: TabSidebarViewController) {
        activeTab?.webView.goForward()
    }

    func tabSidebarDidRequestReload(_ sidebar: TabSidebarViewController) {
        activeTab?.webView.reload()
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didSubmitAddressInput input: String) {
        navigateToAddress(input)
    }
}

// MARK: - WKNavigationDelegate

extension BrowserWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.navigationType == .linkActivated && navigationAction.modifierFlags.contains(.command) {
            if let url = navigationAction.request.url {
                addNewTab(url: url, afterActiveTab: true)
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
            addNewTab(url: url, afterActiveTab: true)
        }
        return nil
    }
}
