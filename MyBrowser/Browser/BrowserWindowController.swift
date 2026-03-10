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
    private var contentScrimView: NSView?

    private var store: TabStore { TabStore.shared }

    // MARK: - Per-window space state

    private(set) var activeSpaceID: UUID?

    private var activeSpace: Space? {
        guard let activeSpaceID else { return nil }
        return store.space(withID: activeSpaceID)
    }

    private var currentTabs: [BrowserTab] {
        activeSpace?.tabs ?? []
    }

    private var selectedTab: BrowserTab? {
        guard let selectedTabID else { return nil }
        return currentTabs.first { $0.id == selectedTabID }
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
        tabSidebar.activeSpaceID = activeSpaceID
        tabSidebar.tabs = currentTabs

        // Apply initial space UI
        if let space = activeSpace {
            tabSidebar.tintColor = space.color
        }
        tabSidebar.updateSpaceButtons(spaces: store.spaces, activeSpaceID: activeSpaceID)

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

    // MARK: - Space Switching (per-window)

    func setActiveSpace(id: UUID) {
        guard let space = store.space(withID: id), activeSpaceID != id else { return }

        // Save current tab selection for the old space
        activeSpace?.selectedTabID = selectedTabID

        activeSpaceID = id
        tabSidebar.activeSpaceID = id
        store.lastActiveSpaceID = id

        tabSidebar.tabs = space.tabs
        tabSidebar.tintColor = space.color
        tabSidebar.updateSpaceButtons(spaces: store.spaces, activeSpaceID: id)

        // Restore the new space's selected tab
        if let savedTabID = space.selectedTabID, space.tabs.contains(where: { $0.id == savedTabID }) {
            selectTab(id: savedTabID)
        } else if let firstTab = space.tabs.first {
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
        guard currentTabs.contains(where: { $0.id == id }) else { return }

        dismissCommandPalette()

        if let previousTab = selectedTab {
            if ownsWebView {
                previousTab.takeSnapshot()
            }
        }
        removeContentViews()

        selectedTabID = id
        activeSpace?.selectedTabID = id
        activeTabSubscriptions.removeAll()

        let tab = currentTabs.first { $0.id == id }!

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

        if let index = currentTabs.firstIndex(where: { $0.id == id }) {
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

        imageView.image = tab.latestSnapshot

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

        palette.show(in: window!.contentView!)
    }

    private func dismissCommandPalette() {
        commandPaletteView?.removeFromSuperview()
        commandPaletteView = nil
        splitScrimView?.removeFromSuperview()
        splitScrimView = nil
        contentScrimView?.removeFromSuperview()
        contentScrimView = nil
    }

    private func deselectAllTabs() {
        selectedTabID = nil
        activeSpace?.selectedTabID = nil
        activeTabSubscriptions.removeAll()
        removeContentViews()
        tabSidebar.addressField.stringValue = ""
        tabSidebar.backButton.isEnabled = false
        tabSidebar.forwardButton.isEnabled = false
        window?.title = "MyBrowser"
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        guard let id = selectedTabID, let space = activeSpace else { return }
        let tabs = currentTabs
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        let nextID: UUID?
        if tabs.count > 1 {
            let newIndex = min(index, tabs.count - 2)
            let candidate = tabs[newIndex == index ? min(index + 1, tabs.count - 1) : newIndex]
            nextID = candidate.id
        } else {
            nextID = nil
        }

        store.closeTab(id: id, in: space)

        if let nextID {
            selectTab(id: nextID)
        } else {
            deselectAllTabs()
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

// MARK: - AddSpaceViewController

private class AddSpaceViewController: NSViewController {
    var onCreate: ((String, String, String) -> Void)?
    var existingSpace: (name: String, emoji: String, colorHex: String)?
    private var selectedColorHex = Space.presetColors[0]
    private var colorButtons: [NSButton] = []
    private var actionButton: NSButton!

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))

        let nameField = NSTextField()
        nameField.placeholderString = "Space name"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.tag = 1

        let emojiField = NSTextField()
        emojiField.placeholderString = "Emoji"
        emojiField.translatesAutoresizingMaskIntoConstraints = false
        emojiField.tag = 2

        let colorStack = NSStackView()
        colorStack.orientation = .horizontal
        colorStack.spacing = 6
        colorStack.translatesAutoresizingMaskIntoConstraints = false

        let initialColorHex = existingSpace?.colorHex ?? Space.presetColors[0]
        selectedColorHex = initialColorHex
        let selectedIndex = Space.presetColors.firstIndex(of: initialColorHex) ?? 0

        for (i, hex) in Space.presetColors.enumerated() {
            let btn = NSButton()
            btn.wantsLayer = true
            btn.isBordered = false
            btn.title = ""
            btn.layer?.cornerRadius = 10
            btn.layer?.backgroundColor = (NSColor(hex: hex) ?? .controlAccentColor).cgColor
            btn.tag = i
            btn.target = self
            btn.action = #selector(colorSelected(_:))
            btn.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                btn.widthAnchor.constraint(equalToConstant: 20),
                btn.heightAnchor.constraint(equalToConstant: 20),
            ])
            if i == selectedIndex {
                btn.layer?.borderWidth = 2
                btn.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.5).cgColor
            }
            colorButtons.append(btn)
            colorStack.addArrangedSubview(btn)
        }

        let buttonTitle = existingSpace != nil ? "Save" : "Create"
        actionButton = NSButton(title: buttonTitle, target: self, action: #selector(createClicked))
        actionButton.bezelStyle = .rounded
        actionButton.keyEquivalent = "\r"
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        if let existing = existingSpace {
            nameField.stringValue = existing.name
            emojiField.stringValue = existing.emoji
        }

        container.addSubview(nameField)
        container.addSubview(emojiField)
        container.addSubview(colorStack)
        container.addSubview(actionButton)

        NSLayoutConstraint.activate([
            nameField.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            nameField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            emojiField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 8),
            emojiField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            emojiField.widthAnchor.constraint(equalToConstant: 60),

            colorStack.topAnchor.constraint(equalTo: emojiField.bottomAnchor, constant: 12),
            colorStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            actionButton.topAnchor.constraint(equalTo: colorStack.bottomAnchor, constant: 12),
            actionButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])

        self.view = container
    }

    @objc private func colorSelected(_ sender: NSButton) {
        selectedColorHex = Space.presetColors[sender.tag]
        for btn in colorButtons {
            btn.layer?.borderWidth = 0
        }
        sender.layer?.borderWidth = 2
        sender.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.5).cgColor
    }

    @objc private func createClicked() {
        let name = (view.viewWithTag(1) as? NSTextField)?.stringValue ?? ""
        let emoji = (view.viewWithTag(2) as? NSTextField)?.stringValue ?? ""
        let finalName = name.isEmpty ? "Space" : name
        let finalEmoji = emoji.isEmpty ? "⭐️" : String(emoji.prefix(1))
        onCreate?(finalName, finalEmoji, selectedColorHex)
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6 else { return nil }
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xFF) / 255.0
        let g = CGFloat((int >> 8) & 0xFF) / 255.0
        let b = CGFloat(int & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
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
        let tabs = currentTabs
        guard index >= 0, index < tabs.count else { return }
        selectTab(id: tabs[index].id)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestCloseTabAt index: Int) {
        guard let space = activeSpace else { return }
        let tabs = currentTabs
        guard index >= 0, index < tabs.count else { return }
        let id = tabs[index].id

        let nextID: UUID?
        if tabs.count > 1 {
            let newIndex = index >= tabs.count - 1 ? index - 1 : index + 1
            nextID = tabs[newIndex].id
        } else {
            nextID = nil
        }

        let wasSelected = (id == selectedTabID)
        store.closeTab(id: id, in: space)

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
        guard let space = activeSpace else { return }
        let adjustedDestination = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        store.moveTab(from: sourceIndex, to: adjustedDestination, in: space)
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

    func tabSidebarDidRequestDeleteSpace(_ sidebar: TabSidebarViewController, spaceID: UUID) {
        guard let space = store.space(withID: spaceID) else { return }

        if !space.tabs.isEmpty {
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
        tabSidebar.tabs = currentTabs
    }

    func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.tabs = currentTabs
    }

    func tabStoreDidReorderTabs(in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.tabs = currentTabs
        if let selectedTabID, let index = currentTabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabSidebar.selectedTabIndex = index
        }
    }

    func tabStoreDidUpdateTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.reloadTab(at: index)
    }

    func tabStoreDidUpdateSpaces() {
        tabSidebar.updateSpaceButtons(spaces: store.spaces, activeSpaceID: activeSpaceID)

        // If our active space was deleted, switch to the first available space
        if activeSpaceID == nil || store.space(withID: activeSpaceID!) == nil, let firstSpace = store.spaces.first {
            setActiveSpace(id: firstSpace.id)
        }
    }
}

// MARK: - CommandPaletteDelegate

extension BrowserWindowController: CommandPaletteDelegate {
    func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String) {
        dismissCommandPalette()
        guard let space = activeSpace else { return }
        let tab = store.addTab(in: space, afterTabID: selectedTabID)
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
            if let url = navigationAction.request.url, let space = activeSpace {
                let tab = store.addTab(in: space, url: url, afterTabID: selectedTabID)
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
        if let url = navigationAction.request.url, let space = activeSpace {
            let tab = store.addTab(in: space, url: url, afterTabID: selectedTabID)
            selectTab(id: tab.id)
        }
        return nil
    }
}
