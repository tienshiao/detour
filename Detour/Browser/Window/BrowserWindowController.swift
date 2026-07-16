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
    private var sidebarHoverGraceActive = false
    private var autoHideWorkItem: DispatchWorkItem?

    var selectedTabID: UUID?
    private var activeTabSubscriptions = Set<AnyCancellable>()
    private var snapshotImageView: NSImageView?
    /// Whether this window currently displays the selected tab's live web view.
    /// Derived from the view hierarchy — a container can only be parented in one
    /// window at a time — so it cannot drift out of sync with reality. Split
    /// panes sit one level deeper (inside `hostedSplitView`), hence descendant.
    private var ownsWebView: Bool {
        guard let container = selectedTab?.webViewContainer else { return false }
        return container.isDescendant(of: contentContainerView)
    }

    /// Hosts the two pane containers when the selected tab is in a split group.
    private var hostedSplitView: NSSplitView?
    /// Per-group memory of the last focused pane, so re-selecting a split row
    /// returns focus to the member the user was last in (default: left pane).
    var lastFocusedSplitMember: [UUID: UUID] = [:]
    private var splitFractionCommit: DispatchWorkItem?
    private var isApplyingSplitLayout = false
    /// Stored fraction that couldn't be applied yet because the split view had
    /// no geometry at claim time (e.g. window restore selects a split before
    /// the first layout pass); applied on the first real resize instead of
    /// letting the 50/50 default get committed over the persisted value.
    private var pendingSplitFraction: Double?
    private var localSnapshot: NSImage?
    private weak var pipContentView: NSView?
    /// One-shot: the next split-hosting claim animates the panes into place.
    /// Set by the split-creation gestures (drop or menu — the sidebar-delegate
    /// extension, hence not private) right before the store mutation whose
    /// observers re-claim this window's content, so only user-witnessed
    /// formation animates — never focus-transfer or convergence re-claims.
    var animateNextSplitClaim = false
    /// Cosmetic veneer that plays the split-formation animation ABOVE the
    /// real (already final) pane layout. The claim path re-runs within a tick
    /// of a split drop (deferred sidebar selection restore → selectTab), so
    /// animating the live views is impossible — the veneer survives those
    /// idempotent re-claims and is removed on completion or when hosting
    /// moves to different content.
    private var splitRevealOverlay: NSView?
    private var splitRevealOverlayMemberIDs: [UUID] = []

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
    /// Transparent content-area overlay for split edge drops, present only while a
    /// local sidebar tab drag session is active (see SplitDropZoneView).
    private var splitDropZoneView: SplitDropZoneView?

    private(set) var isIncognito = false
    private var incognitoSpaceID: UUID?

    enum ContextMenuLinkAction {
        case none, openInNewTab, openInNewWindow
    }
    var contextMenuLinkAction: ContextMenuLinkAction = .none

    var peekOverlayView: PeekOverlayView?
    private var peekTabSubscriptions = Set<AnyCancellable>()
    private var displayTabSubscriptions = Set<AnyCancellable>()
    private var peekWebViewTopConstraint: NSLayoutConstraint?
    private var peekWebViewBottomConstraint: NSLayoutConstraint?
    private var peekWebViewLeadingConstraint: NSLayoutConstraint?
    private var peekWebViewTrailingConstraint: NSLayoutConstraint?

    var store: TabStore { TabStore.shared }

    override var undoManager: UndoManager? {
        store.undoManager
    }

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
        return activeSpace?.pinnedEntries.first { $0.tab?.id == selectedTabID }?.tab
            ?? activeSpace?.profile?.favorites.first { $0.tab?.id == selectedTabID }?.tab
            ?? currentTabs.first { $0.id == selectedTabID }
    }

    var displayTab: BrowserTab? {
        selectedTab?.peekTab ?? selectedTab
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
            tabSidebar.pinnedEntries = activeSpace?.pinnedEntries ?? []
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleContentBlockerRulesChanged),
            name: .contentBlockerRulesDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExtensionTabShouldSelect(_:)),
            name: ExtensionManager.tabShouldSelectNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExtensionsDidChange),
            name: ExtensionManager.extensionsDidChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExtensionPopupOpenURL(_:)),
            name: ExtensionManager.popupOpenURLNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExtensionOpenOptionsPage(_:)),
            name: ExtensionManager.openOptionsPageNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExtensionActionDidChange(_:)),
            name: ExtensionManager.extensionActionDidChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTabRestoredByUndo(_:)),
            name: .tabRestoredByUndo,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSpaceProfileDidSwap(_:)),
            name: .spaceProfileDidSwap,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExtensionPinStateDidChange),
            name: ExtensionManager.extensionPinStateDidChangeNotification,
            object: nil
        )
    }

    @objc private func handleExtensionActionDidChange(_ notification: Notification) {
        guard let extensionID = notification.userInfo?["extensionID"] as? String,
              let ext = ExtensionManager.shared.extension(withID: extensionID) else { return }
        let image = ExtensionManager.iconImage(for: extensionID, ext: ext)
        tabSidebar.fauxAddressBar.updatePinnedExtensionIcon(extensionID: extensionID, image: image)
    }

    @objc private func handleTabRestoredByUndo(_ notification: Notification) {
        guard let tabID = notification.userInfo?["tabID"] as? UUID,
              let spaceID = notification.userInfo?["spaceID"] as? UUID,
              spaceID == activeSpaceID else { return }
        selectTab(id: tabID)
    }

    /// After a profile swap slept the space's tabs, re-select this window's own
    /// displayed tab (waking it under the new profile) so each window keeps its
    /// place. Falls back to the space's selection when our tab no longer
    /// resolves — e.g. it was a favorite backing tab the swap deactivated.
    @objc private func handleSpaceProfileDidSwap(_ notification: Notification) {
        guard let spaceID = notification.userInfo?["spaceID"] as? UUID,
              spaceID == activeSpaceID else { return }
        let candidates = [selectedTabID, activeSpace?.selectedTabID].compactMap { $0 }
        if let id = candidates.first(where: displayableTab(id:)) {
            selectTab(id: id)
        }
    }

    /// Whether an ID resolves to a tab this window could display — mirrors the
    /// guard in `selectTab(id:)`.
    private func displayableTab(id: UUID) -> Bool {
        (activeSpace?.pinnedEntries.contains { $0.tab?.id == id } ?? false)
            || (activeSpace?.profile?.favorites.contains { $0.tab?.id == id } ?? false)
            || currentTabs.contains { $0.id == id }
    }

    @objc private func handleExtensionPopupOpenURL(_ notification: Notification) {
        guard let url = notification.userInfo?["url"] as? URL else { return }
        guard let space = activeSpace else { return }
        let tab = store.addTab(in: space, url: url)
        selectTab(id: tab.id)
    }

    @objc private func handleExtensionOpenOptionsPage(_ notification: Notification) {
        guard let extensionID = notification.userInfo?["extensionID"] as? String,
              let context = ExtensionManager.shared.context(for: extensionID),
              let optionsURL = context.optionsPageURL,
              let extConfig = context.webViewConfiguration,
              let space = activeSpace else { return }

        let tab = store.addExtensionTab(in: space, url: optionsURL, configuration: extConfig)
        selectTab(id: tab.id)
    }

    @objc private func handleExtensionsDidChange() {
        updatePinnedExtensionIcons()
    }

    @objc private func handleExtensionPinStateDidChange() {
        updatePinnedExtensionIcons()
    }

    deinit {
        store.removeObserver(self)
        DownloadManager.shared.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Space Switching (per-window)

    func setActiveSpace(id: UUID, selectTab: Bool = true) {
        guard let space = store.space(withID: id), activeSpaceID != id else { return }

        // Save current tab selection for the old space
        activeSpace?.selectedTabID = selectedTabID

        hidePeekUI()

        activeSpaceID = id
        tabSidebar.activeSpaceID = id
        if !isIncognito {
            store.lastActiveSpaceID = id
        }

        tabSidebar.resetState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders, tabs: space.tabs)
        tabSidebar.tintColor = space.color
        if let profile = space.profile {
            tabSidebar.updateFavorites(profile.favorites, selectedTabID: selectedTabID)
        }
        tabSidebar.updateSpaceButtons(spaces: store.spaces, activeSpaceID: id)

        if selectTab {
            // Restore the new space's selected tab
            if let savedTabID = space.selectedTabID,
               space.tabs.contains(where: { $0.id == savedTabID }) || space.pinnedEntries.contains(where: { $0.tab?.id == savedTabID }) {
                self.selectTab(id: savedTabID)
            } else if let firstLivePinnedTab = space.pinnedEntries.first(where: { $0.tab != nil })?.tab {
                self.selectTab(id: firstLivePinnedTab.id)
            } else if let firstTab = space.tabs.first {
                self.selectTab(id: firstTab.id)
            } else {
                deselectAllTabs()
            }
        } else {
            deselectAllTabs()
        }

        // Update pinned extension icons for the new profile
        updatePinnedExtensionIcons()

        store.scheduleSave()
    }

    @objc func nextSpace(_ sender: Any?) { navigateSpace(offset: 1) }

    @objc func previousSpace(_ sender: Any?) { navigateSpace(offset: -1) }

    private func navigateSpace(offset: Int) {
        let list = store.nonIncognitoSpaces
        guard let activeID = activeSpaceID,
              let i = list.firstIndex(where: { $0.id == activeID }) else { return }
        let target = i + offset
        guard target >= 0, target < list.count else { return }
        tabSidebar.animateToSpace(id: list[target].id)
    }

    private func canNavigateSpace(offset: Int) -> Bool {
        let list = store.nonIncognitoSpaces
        guard let activeID = activeSpaceID,
              let i = list.firstIndex(where: { $0.id == activeID }) else { return false }
        let target = i + offset
        return target >= 0 && target < list.count
    }

    @objc func selectSpaceFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        tabSidebar.animateToSpace(id: id)
    }

    @objc func openSpacesSettings(_ sender: Any?) {
        SettingsWindowController.shared.showSpacesPane()
    }

    /// Update pinned extension icons in the faux address bar for the current profile.
    func updatePinnedExtensionIcons() {
        guard let profileID = activeSpace?.profile?.id else {
            tabSidebar.fauxAddressBar.setPinnedExtensions([])
            return
        }
        let pinned = ExtensionManager.shared.pinnedExtensions(for: profileID)
        let items = pinned.map { ext in
            (id: ext.id, image: ExtensionManager.iconImage(for: ext.id, ext: ext))
        }
        tabSidebar.fauxAddressBar.setPinnedExtensions(items)
    }

    // MARK: - Setup

    /// An empty toolbar is required so that the traffic light buttons (close/minimize/zoom)
    /// are positioned inside the sidebar area rather than overlapping the content view.
    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "BrowserToolbar")
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
        window?.contentView?.wantsLayer = true

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
            edgeView.widthAnchor.constraint(equalToConstant: 20),
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
            sidebarHoverGraceActive = true
            splitViewController.toggleSidebar(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.sidebarHoverGraceActive = false
            }
        } else if zone == "sidebar" && sidebarOpenedByHover {
            autoHideWorkItem?.cancel()
            autoHideWorkItem = nil
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard let userInfo = event.trackingArea?.userInfo,
              let zone = userInfo["zone"] as? String else { return }
        if zone == "sidebar" && sidebarOpenedByHover && !sidebarHoverGraceActive {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.sidebarOpenedByHover else { return }
                self.sidebarOpenedByHover = false
                self.splitViewController.toggleSidebar(nil)
            }
            autoHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
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

    private var linkStatusBarConstraints: [NSLayoutConstraint] = []

    private func setupLinkStatusBar() {
        linkStatusBar.isHidden = true
        linkStatusBar.translatesAutoresizingMaskIntoConstraints = false
        anchorLinkStatusBar(to: contentContainerView)
    }

    /// Pins linkStatusBar to the bottom-left of `view` with a 4pt margin.
    /// When `view` is the active webView, the bar tracks the webView's bounds —
    /// so a docked Web Inspector shrinking the webView slides the bar up
    /// instead of letting it cover the inspector.
    private func anchorLinkStatusBar(to view: NSView) {
        NSLayoutConstraint.deactivate(linkStatusBarConstraints)
        linkStatusBarConstraints.removeAll()
        if linkStatusBar.superview !== view {
            view.addSubview(linkStatusBar, positioned: .above, relativeTo: nil)
        }
        linkStatusBarConstraints = [
            linkStatusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            linkStatusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            linkStatusBar.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.5),
            linkStatusBar.heightAnchor.constraint(equalToConstant: 22),
        ]
        NSLayoutConstraint.activate(linkStatusBarConstraints)
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
        let isPinnedTab = activeSpace?.pinnedEntries.contains(where: { $0.tab?.id == id }) ?? false
        let isFavoriteTab = activeSpace?.profile?.favorites.contains(where: { $0.tab?.id == id }) ?? false
        let isNormalTab = currentTabs.contains(where: { $0.id == id })
        guard isPinnedTab || isFavoriteTab || isNormalTab else { return }

        dismissCommandPalette()

        if let previousTab = selectedTab {
            // Enter PiP for peek before hidePeekUI() removes it from the hierarchy.
            if let peekTab = previousTab.peekTab, peekTab.isPlayingAudio {
                peekTab.enterPictureInPicture()
                pipContentView = peekTab.webView
            }
            hidePeekUI()
            // Stamp every pane of a split: the unfocused pane has no selection
            // of its own, and without a timestamp it would never go stale.
            for member in splitMembers(of: previousTab) {
                member.lastDeselectedAt = Date()
            }
            if previousTab.isPlayingAudio {
                previousTab.enterPictureInPicture()
                // Keep the container in the hierarchy so WebKit can capture the
                // video's on-screen frame for the PiP animation origin.
                pipContentView = previousTab.webViewContainer
            }
        } else {
            hidePeekUI()
        }
        removeContentViews()
        localSnapshot = nil

        selectedTabID = id
        activeSpace?.selectedTabID = id
        activeTabSubscriptions.removeAll()
        dragHandle.isHidden = false

        // Notify extensions of tab activation
        if let spaceID = activeSpaceID {
            NotificationCenter.default.post(
                name: ExtensionManager.tabActivatedNotification,
                object: nil,
                userInfo: ["tabID": id, "spaceID": spaceID]
            )
        }

        guard let tab = selectedTab else { return }
        // A pinned split wakes BOTH sides: activate a dormant partner entry
        // (the pinned analog of the sleeping-member wake below) so the group
        // resolves to two live panes before hosting.
        if let space = activeSpace,
           let entry = space.pinnedEntries.first(where: { $0.tab?.id == id }),
           let groupID = entry.splitGroupID {
            for member in store.pinnedSplitEntries(groupID: groupID, in: space) where member.tab == nil {
                store.activatePinnedEntry(id: member.id, in: space)
            }
        }
        // Both panes of a split are on screen together: wake and un-stamp the
        // partner too, or it would sleep (or stay asleep) behind a live pane.
        let members = splitMembers(of: tab)
        for member in members {
            member.lastDeselectedAt = nil
            wakeIfNeeded(member)
        }
        if members.count == 2, let space = activeSpace,
           let groupID = store.splitGroup(containing: tab.id, in: space)?.groupID {
            lastFocusedSplitMember[groupID] = tab.id
        }

        bindSelectedTabChrome()

        if let space = activeSpace {
            tabSidebar.applyState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders,
                                  tabs: currentTabs, selectedTabID: id)
        }

        tabSidebar.suppressingSelectionCallbacks {
            if let index = activeSpace?.pinnedEntries.firstIndex(where: { $0.tab?.id == id }) {
                tabSidebar.selectedPinnedTabIndex = index
            } else if let index = currentTabs.firstIndex(where: { $0.id == id }) {
                tabSidebar.selectedTabIndex = index
            } else if isFavoriteTab {
                // Favorite tabs aren't in the table — deselect any table row
                tabSidebar.tableView.deselectAll(nil)
            }
        }

        // Update favorite selection highlight
        tabSidebar.updateFavoriteSelection(selectedTabID: id)

        if window?.isKeyWindow == true || members.allSatisfy({ $0.webViewContainer?.superview == nil }) {
            claimWebView(for: tab)
        } else {
            showSnapshot(for: tab)
        }

        tab.exitPictureInPicture()
        tab.peekTab?.exitPictureInPicture()

        // Restore peek overlay if the incoming tab has one
        restorePeekOverlayIfNeeded()
    }

    /// The selected tab's split partners (both panes, visual order) — or just
    /// the tab itself when it isn't in a split group.
    func splitMembers(of tab: BrowserTab) -> [BrowserTab] {
        guard let space = activeSpace,
              let group = store.splitGroup(containing: tab.id, in: space) else { return [tab] }
        return group.members
    }

    /// Script message handlers this controller registers on every owned pane webview.
    private static let ownedScriptHandlerNames = ["linkHover", BlockedResourceTracker.messageName, "editableFieldFocus"]

    /// Wake a sleeping split member alongside the focused pane, mirroring the
    /// wake path in `selectTab` (including the extension open/activate notify
    /// that `notifyExistingTabs` skipped while the tab slept). Guards on the
    /// missing webView rather than `isSleeping` so a tab that lost its webView
    /// without being flagged asleep is also rebuilt instead of hosting as an
    /// empty pane (`wake()` re-guards, so a live webView is never replaced).
    private func wakeIfNeeded(_ tab: BrowserTab) {
        guard tab.webView == nil else { return }
        tab.wake()
        if let space = activeSpace, let profile = space.profile {
            for context in profile.extensionContexts.values {
                context.didOpenTab(tab)
                context.didActivateTab(tab, previousActiveTab: nil)
            }
        }
    }

    private func claimWebView(for tab: BrowserTab) {
        let members = splitMembers(of: tab)
        // Rebuild any missing webView before hosting — selectTab wakes members
        // itself, but the refreshSplitHostingIfNeeded path arrives here without
        // that pass.
        for member in members {
            wakeIfNeeded(member)
        }
        if members.count == 2 {
            claimSplitWebViews(members: members, focused: tab)
        } else {
            claimSingleWebView(for: tab)
        }
        // Safety net: a claimed webview with no content — its load never
        // started, or its web content process died while unparented — hosts
        // as a dead white pane. Kick a load of the tab's last known URL.
        for member in members {
            if let webView = member.webView, webView.url == nil, !webView.isLoading,
               let url = member.url {
                member.load(url)
            }
        }
    }

    private func wireOwnedWebView(_ webView: WKWebView) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        let ucc = webView.configuration.userContentController
        for name in Self.ownedScriptHandlerNames {
            ucc.removeScriptMessageHandler(forName: name)
            ucc.add(self, name: name)
        }
    }

    private func postOwnershipChanged(tabIDs: [UUID], focusedID: UUID, snapshot: NSImage?) {
        var userInfo: [String: Any] = ["tabID": focusedID, "tabIDs": tabIDs]
        if let snapshot {
            userInfo["snapshot"] = snapshot
        }
        NotificationCenter.default.post(
            name: .webViewOwnershipChanged,
            object: self,
            userInfo: userInfo
        )
    }

    // MARK: - Content-area split drop zone

    /// The tab a content-area edge drop would split with: the selected tab, only
    /// while it is an ungrouped normal tab (pinned/favorite backing tabs are not
    /// in space.tabs; grouped tabs reject — one split per tab).
    var splitDropTargetTabID: UUID? {
        guard let space = activeSpace, let id = selectedTabID,
              let tab = space.tabs.first(where: { $0.id == id }),
              tab.splitGroupID == nil else { return nil }
        return id
    }

    func installSplitDropZone() {
        guard splitDropZoneView == nil, splitDropTargetTabID != nil else { return }
        let zone = SplitDropZoneView(frame: contentContainerView.bounds)
        zone.autoresizingMask = [.width, .height]
        zone.payloadValidator = { [weak self] payload in
            guard let self else { return false }
            return validateContentSplitDrop(payload: payload, sidebarID: self.tabSidebar.sidebarID,
                                            activeSpaceID: self.activeSpaceID, targetTabID: self.splitDropTargetTabID)
        }
        zone.onDrop = { [weak self] payload, edge in
            // The payload was validated in the same stack (performDragOperation runs
            // payloadValidator first); what can have gone stale since the drag began
            // is the DRAGGED tab — another window sharing the space may have closed,
            // pinned, or split it. Re-resolve it like the sidebar's resolveDragSource
            // does, so acceptance feedback matches whether createSplit will act.
            guard let self, let space = self.activeSpace, let targetID = self.splitDropTargetTabID,
                  space.tabs.contains(where: { $0.id == payload.itemID && $0.splitGroupID == nil }) else { return false }
            self.tabSidebar.performContentAreaSplitDrop(draggedTabID: payload.itemID, targetTabID: targetID, edge: edge)
            return true
        }
        contentContainerView.addSubview(zone, positioned: .below, relativeTo: dragHandle)
        splitDropZoneView = zone
    }

    func removeSplitDropZone() {
        splitDropZoneView?.removeFromSuperview()
        splitDropZoneView = nil
    }

    private func claimSingleWebView(for tab: BrowserTab) {
        // Single hosting means the split a reveal was playing for is gone.
        removeSplitRevealOverlay()
        guard let webView = tab.webView else { return }
        tab.ensureWebViewContainer()
        guard let container = tab.webViewContainer else { return }

        if container.superview === contentContainerView {
            container.isHidden = false
            container.frame = contentContainerView.bounds
            anchorLinkStatusBar(to: webView)
            return
        }

        // Snapshot what the previous owner displayed at its current size: the
        // whole split view when the pane was hosted in one (both panes, one
        // image), otherwise the container (webView + any docked inspector).
        let snapshotTarget = (container.superview as? NSSplitView) ?? container
        let priorSnapshot = snapshotWithinSuperview(of: snapshotTarget)

        removeContentViews()

        container.removeFromSuperview()
        resetSplitPaneChrome(container)
        wireOwnedWebView(webView)

        // Use frame-based layout (not constraints) for WKWebView — Auto Layout breaks Web Inspector.
        contentContainerView.addSubview(container, positioned: .below, relativeTo: dragHandle)
        container.frame = contentContainerView.bounds

        anchorLinkStatusBar(to: webView)

        postOwnershipChanged(tabIDs: [tab.id], focusedID: tab.id, snapshot: priorSnapshot)
    }

    /// Hosts both panes of the focused tab's split group in an NSSplitView.
    /// NSSplitView manages child frames directly (no Auto Layout inside), which
    /// preserves the frame-based-layout requirement that keeps the docked Web
    /// Inspector working.
    private func claimSplitWebViews(members: [BrowserTab], focused: BrowserTab) {
        // A running reveal for these same members keeps playing over the
        // idempotent re-claim; any other content change makes it stale.
        if splitRevealOverlay != nil, splitRevealOverlayMemberIDs != members.map(\.id) {
            removeSplitRevealOverlay()
        }
        // Consume the one-shot BEFORE the teardown below, while the pane the
        // user was looking at is still on screen to snapshot.
        let reveal = takeSplitRevealContext(members: members)

        for member in members {
            member.ensureWebViewContainer()
        }
        let containers = members.compactMap(\.webViewContainer)
        guard containers.count == 2, let focusedWebView = focused.webView else {
            claimSingleWebView(for: focused)
            return
        }
        // The stored fraction lives on the tabs for a normal split and on the
        // entries for a pinned split — the store helper reads either.
        let fraction = activeSpace.flatMap { store.splitFraction(containing: members[0].id, in: $0) } ?? 0.5

        // Already hosting exactly these panes — just refresh.
        if hostedSplitMatches(members), let split = hostedSplitView {
            split.isHidden = false
            split.frame = hostedSplitFrame
            applySplitFraction(fraction, to: split)
            updateSplitPaneFocus()
            anchorLinkStatusBar(to: focusedWebView)
            return
        }

        // Snapshot what the previous owner displayed (see claimSingleWebView).
        let snapshotTarget = containers.compactMap { $0.superview as? NSSplitView }.first
            ?? containers.first { $0.superview != nil }
        let priorSnapshot = snapshotTarget.flatMap { snapshotWithinSuperview(of: $0) }

        removeContentViews()

        for member in members {
            member.webViewContainer?.removeFromSuperview()
            if let webView = member.webView {
                wireOwnedWebView(webView)
            }
        }

        let split = HostedSplitView()
        split.isVertical = true
        split.delegate = self
        split.onEffectiveAppearanceChange = { [weak self] in self?.updateSplitPaneFocus() }
        split.translatesAutoresizingMaskIntoConstraints = true
        split.autoresizingMask = [.width, .height]
        split.frame = hostedSplitFrame
        for container in containers {
            container.isHidden = false
            split.addArrangedSubview(container)
        }
        contentContainerView.addSubview(split, positioned: .below, relativeTo: dragHandle)
        hostedSplitView = split
        applySplitFraction(fraction, to: split)
        updateSplitPaneFocus()

        anchorLinkStatusBar(to: focusedWebView)

        postOwnershipChanged(tabIDs: members.map(\.id), focusedID: focused.id, snapshot: priorSnapshot)

        // A same-members re-claim (a left-edge drop's selection restore lands
        // on the dragged member → selectTab → full rebuild) re-adds the split
        // as the highest content subview, covering a still-playing veneer —
        // lift it back on top or the rest of the animation plays hidden.
        if let overlay = splitRevealOverlay {
            overlay.removeFromSuperview()
            contentContainerView.addSubview(overlay, positioned: .below, relativeTo: dragHandle)
        }

        if let reveal {
            installSplitRevealOverlay(reveal, split: split, members: members)
        }
    }

    private func applySplitFraction(_ fraction: Double, to split: NSSplitView) {
        let available = split.bounds.width - split.dividerThickness
        guard available > 0 else {
            pendingSplitFraction = fraction
            return
        }
        pendingSplitFraction = nil
        isApplyingSplitLayout = true
        // Tile both panes explicitly before setPosition. setPosition resizes
        // the divider's neighbors from their CURRENT frames, preserving far
        // edges — a container carrying a stale frame from an earlier hosting
        // (e.g. it was the left pane before the group re-formed with it on
        // the right) collapses to zero width and shows as a dead white half,
        // and nothing retiles it until the window resizes.
        let rects = splitPaneRects(in: split.bounds, inset: 0,
                                   gap: split.dividerThickness, fraction: fraction)
        let panes = split.arrangedSubviews
        if panes.count == 2 {
            panes[0].frame = rects.left
            panes[1].frame = rects.right
        }
        split.setPosition(rects.left.width, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        isApplyingSplitLayout = false
    }

    /// Runs a pending debounced divider-fraction write immediately instead of
    /// dropping it — content teardown inside the debounce window (tab switch,
    /// ownership handoff) must not lose the user's divider position.
    private func flushPendingSplitFractionCommit() {
        guard let commit = splitFractionCommit else { return }
        splitFractionCommit = nil
        commit.perform()
        commit.cancel()
    }

    /// Fullscreen drops the card look: a gutter and rounded corners against
    /// the bare screen edge waste space without the window chrome that
    /// motivated them, so the panes go full bleed and square.
    private var hostedSplitIsFullBleed: Bool {
        window?.styleMask.contains(.fullScreen) == true
    }

    private var hostedSplitCornerRadius: CGFloat {
        hostedSplitIsFullBleed ? 0 : UIConstants.splitPaneCornerRadius
    }

    /// The hosted split's frame: inset from the content area so the panes read
    /// as rounded cards (matching the drop-zone previews) instead of running
    /// into the window edges. Full bleed in fullscreen.
    private var hostedSplitFrame: NSRect {
        let inset = hostedSplitIsFullBleed ? 0 : UIConstants.splitPaneInset
        return contentContainerView.bounds.insetBy(dx: inset, dy: inset)
    }

    // MARK: - Split formation reveal

    /// What the formation animation needs from the moment before the claim
    /// tears the single hosting down: which pane the user was already looking
    /// at, and its full-bleed pixels.
    private struct SplitRevealContext {
        let existingIndex: Int
        let snapshot: NSImage?
    }

    /// Consumes the one-shot `animateNextSplitClaim`. Returns a context only
    /// for the transition the user actually watched: this window hosting one
    /// of `members` full-bleed (not a snapshot stand-in, not already a split).
    private func takeSplitRevealContext(members: [BrowserTab]) -> SplitRevealContext? {
        guard animateNextSplitClaim else { return nil }
        animateNextSplitClaim = false
        guard hostedSplitView == nil,
              contentContainerView.bounds.width > 0,
              let index = members.firstIndex(where: { $0.webViewContainer?.superview === contentContainerView }),
              let container = members[index].webViewContainer
        else { return nil }
        return SplitRevealContext(existingIndex: index, snapshot: snapshotImage(of: container))
    }

    /// Plays the formation animation over the freshly installed (already
    /// final) split: a card with the pre-drop content shrinks from full bleed
    /// into its pane while the incoming pane's card slides in from its edge,
    /// then the veneer fades to reveal the live panes. Purely cosmetic — the
    /// re-claims that follow a split drop (deferred sidebar selection restore
    /// → selectTab) rebuild identical content beneath it, so it never has to
    /// survive state it didn't expect.
    private func installSplitRevealOverlay(_ reveal: SplitRevealContext, split: NSSplitView,
                                           members: [BrowserTab]) {
        removeSplitRevealOverlay()
        let panes = split.arrangedSubviews
        guard panes.count == 2 else { return }
        let finalFrames = panes.map { split.convert($0.frame, to: contentContainerView) }
        let incomingIndex = 1 - reveal.existingIndex

        let overlay = ClickThroughView(frame: contentContainerView.bounds)
        overlay.autoresizingMask = [.width, .height]
        // The incoming card starts beyond the content area's edge; without
        // clipping, a left-edge start would draw over the sidebar.
        overlay.clipsToBounds = true

        let existingCard = makeSplitRevealCard(snapshot: reveal.snapshot)
        existingCard.frame = contentContainerView.bounds
        existingCard.layer?.cornerRadius = 0

        // The incoming pane may never have rendered (fresh wake) — its card
        // falls back to the window background and the live pane appears at
        // the fade.
        let incomingCard = makeSplitRevealCard(
            snapshot: members[incomingIndex].webView.flatMap { snapshotImage(of: $0) })
        let incomingFinal = finalFrames[incomingIndex]
        let startX = incomingIndex == 0
            ? contentContainerView.bounds.minX - incomingFinal.width
            : contentContainerView.bounds.maxX
        incomingCard.frame = NSRect(x: startX, y: incomingFinal.minY,
                                    width: incomingFinal.width, height: incomingFinal.height)

        overlay.addSubview(existingCard)
        overlay.addSubview(incomingCard)
        contentContainerView.addSubview(overlay, positioned: .below, relativeTo: dragHandle)
        splitRevealOverlay = overlay
        splitRevealOverlayMemberIDs = members.map(\.id)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            existingCard.animator().frame = finalFrames[reveal.existingIndex]
            existingCard.layer?.cornerRadius = self.hostedSplitCornerRadius
            incomingCard.animator().frame = incomingFinal
        }, completionHandler: { [weak overlay] in
            guard let overlay else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                overlay.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak overlay] in
                guard let overlay else { return }
                overlay.removeFromSuperview()
                if let self, self.splitRevealOverlay === overlay {
                    self.splitRevealOverlay = nil
                    self.splitRevealOverlayMemberIDs = []
                }
            })
        })
    }

    private func removeSplitRevealOverlay() {
        splitRevealOverlay?.removeFromSuperview()
        splitRevealOverlay = nil
        splitRevealOverlayMemberIDs = []
    }

    /// A pane stand-in for the reveal veneer: a rounded card showing a static
    /// snapshot anchored at its top-left (cropping, not squishing, as the card
    /// resizes — the closest match to how live web content reflows) over the
    /// window background color.
    private func makeSplitRevealCard(snapshot: NSImage?) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        guard let layer = card.layer else { return card }
        layer.masksToBounds = true
        layer.cornerRadius = hostedSplitCornerRadius
        layer.cornerCurve = .continuous
        layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        if let snapshot {
            var rect = NSRect(origin: .zero, size: snapshot.size)
            if let cgImage = snapshot.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                layer.contents = cgImage
                layer.contentsGravity = .topLeft
                layer.contentsScale = window?.backingScaleFactor ?? 2
            }
        }
        return card
    }

    /// Pane chrome for a hosted split: each pane is a rounded, shadowed card,
    /// the focused one marked by a hairline border. The shadow requires the
    /// pane layer NOT to clip (masksToBounds kills the shadow), so content is
    /// clipped one level down by WebViewContainerView, which also covers
    /// subviews WebKit attaches later (the docked inspector).
    private func updateSplitPaneFocus() {
        guard let split = hostedSplitView else { return }
        let focusedContainer = selectedTab?.webViewContainer
        // Resolve the dynamic border color under the split's own appearance;
        // HostedSplitView re-runs this pass when that appearance changes.
        var focusBorderColor: CGColor?
        split.effectiveAppearance.performAsCurrentDrawingAppearance {
            focusBorderColor = UIConstants.splitPaneFocusBorderColor.cgColor
        }
        let radius = hostedSplitCornerRadius
        for pane in split.arrangedSubviews {
            pane.wantsLayer = true
            let isFocused = pane === focusedContainer
            pane.layer?.borderWidth = isFocused ? 2 : 0
            pane.layer?.borderColor = isFocused ? focusBorderColor : nil
            pane.layer?.cornerRadius = radius
            pane.layer?.cornerCurve = .continuous
            pane.layer?.masksToBounds = false
            pane.layer?.shadowColor = NSColor.black.cgColor
            pane.layer?.shadowOpacity = hostedSplitIsFullBleed ? 0 : UIConstants.splitPaneShadowOpacity
            pane.layer?.shadowRadius = UIConstants.splitPaneShadowRadius
            pane.layer?.shadowOffset = UIConstants.splitPaneShadowOffset
            (pane as? WebViewContainerView)?.contentCornerRadius = radius
        }
        updateSplitPaneShadowPaths()
    }

    /// Keeps each pane's shadow shape in sync with its frame: shadowPath does
    /// not track bounds changes, and without an explicit path CA re-derives
    /// the shadow from the composited web content on every frame.
    private func updateSplitPaneShadowPaths() {
        guard let split = hostedSplitView else { return }
        let radius = hostedSplitCornerRadius
        for pane in split.arrangedSubviews {
            pane.layer?.shadowPath = CGPath(roundedRect: pane.bounds,
                                            cornerWidth: radius,
                                            cornerHeight: radius,
                                            transform: nil)
        }
    }

    /// Strips split-pane chrome from a container returning to full-bleed
    /// single hosting, where a leftover radius or shadow would show against
    /// the window edges.
    private func resetSplitPaneChrome(_ pane: NSView) {
        pane.layer?.borderWidth = 0
        pane.layer?.cornerRadius = 0
        pane.layer?.shadowOpacity = 0
        pane.layer?.shadowPath = nil
        (pane as? WebViewContainerView)?.contentCornerRadius = 0
    }

    /// Whether the hosted split view is parented in this window's content area
    /// and shows exactly `members`' containers, in order. The single source of
    /// truth for "already hosting these panes" — claim and refresh both use it.
    private func hostedSplitMatches(_ members: [BrowserTab]) -> Bool {
        guard let split = hostedSplitView, split.superview === contentContainerView else { return false }
        let containers = members.compactMap(\.webViewContainer)
        return containers.count == members.count && split.arrangedSubviews == containers
    }

    /// Re-claims content after a structural split change that didn't go through
    /// `selectTab` — a pane closed out from under the split, Separate Tabs, or a
    /// split formed around the selected tab (context menu) — so the hosted view
    /// (single container vs split view) matches the selected tab's group state.
    func refreshSplitHostingIfNeeded() {
        guard let tab = selectedTab, ownsWebView else { return }
        let members = splitMembers(of: tab)
        let hostingSplit = hostedSplitView?.superview === contentContainerView
        let matches = members.count == 2 ? hostedSplitMatches(members) : !hostingSplit
        guard !matches else { return }
        claimWebView(for: tab)
    }

    private func snapshotImage(of view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    /// Snapshot of `view` composed at its frame within its superview's bounds.
    /// A hosted split is inset from the content area; snapshotting just the
    /// split and displaying it full-bleed would shift and rescale the stand-in
    /// relative to what was live. Composing keeps the gutters, so the image
    /// maps 1:1 onto the content area. Full-bleed views pass through unchanged.
    private func snapshotWithinSuperview(of view: NSView) -> NSImage? {
        guard let image = snapshotImage(of: view) else { return nil }
        guard let superview = view.superview, view.frame != superview.bounds,
              superview.bounds.width > 0, superview.bounds.height > 0 else { return image }
        let frame = view.frame
        return NSImage(size: superview.bounds.size, flipped: false) { _ in
            image.draw(in: frame)
            return true
        }
    }

    private func showSnapshot(for tab: BrowserTab) {
        removeSplitRevealOverlay()
        removeContentViews()

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

        // Prefer the snapshot handed over when another window took ownership;
        // otherwise render the tab's live web view (it's a shared instance, even
        // if currently parented in another window) so we don't show an empty
        // dimmed pane. Falls back to nil (empty) only for sleeping tabs.
        imageView.image = localSnapshot ?? liveSnapshot(for: tab)
    }

    /// Renders the tab's live content wherever it is currently parented: the
    /// whole split view when the tab's group is hosted in another window (both
    /// panes in one image), else the tab's own webview.
    private func liveSnapshot(for tab: BrowserTab) -> NSImage? {
        let members = splitMembers(of: tab)
        if members.count == 2,
           let split = members[0].webViewContainer?.superview as? NSSplitView {
            return snapshotWithinSuperview(of: split)
        }
        return tab.webView.flatMap { snapshotImage(of: $0) }
    }

    private func removeContentViews() {
        emptyStateLabel.isHidden = true
        // Reparent before the container teardown below removes its subtree.
        if linkStatusBar.superview !== contentContainerView {
            anchorLinkStatusBar(to: contentContainerView)
        }
        flushPendingSplitFractionCommit()
        let currentPeekWebView = selectedTab?.peekTab?.webView
        // The split-reveal veneer is NOT removed here: the claim that follows a
        // split drop re-runs within a tick (deferred sidebar selection restore
        // → selectTab) and must not cut the animation short. The claim paths
        // remove it themselves when hosting moves to different content.
        for subview in contentContainerView.subviews where subview !== findBar && subview !== dragHandle && subview !== peekOverlayView && subview !== currentPeekWebView && subview !== linkStatusBar && subview !== emptyStateLabel && subview !== pipContentView && subview !== splitDropZoneView && subview !== splitRevealOverlay {
            for webView in webViews(in: subview) {
                for name in Self.ownedScriptHandlerNames {
                    webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
                }
                (webView as? BrowserWebView)?.isEditingWebContent = false
            }
            // Dismantle a split view before removing it so pane containers end
            // up superview-less, like a single tab's container after handoff —
            // downstream checks treat "has a superview" as "hosted somewhere".
            // The pane entering PiP is instead kept parented as a direct
            // subview (mirroring the single-tab path) so WebKit can capture
            // the animation origin; the delayed cleanup below removes it.
            if subview === hostedSplitView, let split = subview as? NSSplitView {
                for pane in split.arrangedSubviews {
                    let frameInContent = split.convert(pane.frame, to: contentContainerView)
                    pane.removeFromSuperview()
                    resetSplitPaneChrome(pane)
                    if pane === pipContentView {
                        pane.frame = frameInContent
                        contentContainerView.addSubview(pane, positioned: .below, relativeTo: dragHandle)
                    }
                }
                hostedSplitView = nil
                pendingSplitFraction = nil
            }
            subview.removeFromSuperview()
        }
        snapshotImageView = nil
        webViewTopConstraint = nil
        linkStatusBar.hide()

        // Clean up the PiP content view after WebKit has captured the animation origin.
        if let pipping = pipContentView {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                // If the tab was re-selected within the delay, its container is
                // now the active owned content — don't rip it out; just drop
                // the stale PiP reference. Descendant, not direct-subview: a
                // re-selected split pane lives inside the hosted split view.
                if pipping === self.selectedTab?.webViewContainer, pipping.isDescendant(of: self.contentContainerView) {
                    if self.pipContentView === pipping { self.pipContentView = nil }
                    return
                }
                pipping.removeFromSuperview()
                if self.pipContentView === pipping { self.pipContentView = nil }
            }
        }
    }

    /// Returns the tab WKWebViews under a direct subview of `contentContainerView`.
    /// Subviews may be raw webviews (peek, PiP), a `BrowserTab.webViewContainer`
    /// wrapping the tab's webview as its first subview, or a hosted split view
    /// holding two such containers. Deliberately shallow — never recurses into
    /// webview or inspector internals.
    private func webViews(in subview: NSView) -> [WKWebView] {
        if let webView = subview as? WKWebView { return [webView] }
        if let split = subview as? NSSplitView {
            return split.arrangedSubviews.compactMap { pane in
                pane.subviews.first { $0 is WKWebView } as? WKWebView
            }
        }
        return (subview.subviews.first { $0 is WKWebView } as? WKWebView).map { [$0] } ?? []
    }

    /// Rebinds all selected-tab chrome (display bindings + window title) to the
    /// current `selectedTab`. Split pane-focus changes call this without
    /// re-running the content-view swap — both panes are already hosted.
    private func bindSelectedTabChrome() {
        activeTabSubscriptions.removeAll()
        bindDisplayTab()
        guard let tab = selectedTab else { return }
        tab.$title
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                self?.window?.title = title
            }
            .store(in: &activeTabSubscriptions)
    }

    /// A pane webview became first responder: move pane focus to its member.
    /// The address bar, nav buttons, find bar, and extensions all key off
    /// `selectedTabID`, which always identifies a specific member, so this is
    /// a chrome rebind only.
    func browserWebViewDidBecomeFirstResponder(_ webView: BrowserWebView) {
        // While a peek is open it owns the interaction (the overlay is modal);
        // retargeting selection out from under it would strand the outgoing
        // pane's overlay — mouse paths can't get here, but keyboard key-view
        // cycling can.
        guard peekOverlayView == nil,
              hostedSplitView != nil,
              let current = selectedTab,
              let space = activeSpace,
              let group = store.splitGroup(containing: current.id, in: space),
              let member = group.members.first(where: { $0.webView === webView }),
              member.id != selectedTabID else { return }

        selectedTabID = member.id
        activeSpace?.selectedTabID = member.id
        lastFocusedSplitMember[group.groupID] = member.id

        bindSelectedTabChrome()
        anchorLinkStatusBar(to: webView)
        updateSplitPaneFocus()

        // Same sidebar row stays selected; retarget its representative member
        // so the row shows the focused pane's title. A pinned split member
        // isn't in currentTabs (pinTab removes the backing tab from space.tabs),
        // so update the pinned selection instead — mirroring the selectTab path.
        if let index = currentTabs.firstIndex(where: { $0.id == member.id }) {
            tabSidebar.suppressingSelectionCallbacks {
                tabSidebar.selectedTabIndex = index
            }
        } else if let pinnedIndex = activeSpace?.pinnedEntries.firstIndex(where: { $0.tab?.id == member.id }) {
            tabSidebar.suppressingSelectionCallbacks {
                tabSidebar.selectedPinnedTabIndex = pinnedIndex
            }
        }
        reloadSelectedTabSidebarCell()

        if let spaceID = activeSpaceID {
            NotificationCenter.default.post(
                name: ExtensionManager.tabActivatedNotification,
                object: nil,
                userInfo: ["tabID": member.id, "spaceID": spaceID]
            )
        }

        // A saved peek on this pane stays dormant while the pane is unfocused;
        // focusing it restores the peek, matching tab-switch behavior.
        restorePeekOverlayIfNeeded()
    }

    private func bindDisplayTab() {
        displayTabSubscriptions.removeAll()
        guard let tab = displayTab else { return }

        tab.$url
            .receive(on: RunLoop.main)
            .sink { [weak self] url in
                self?.tabSidebar.fauxAddressBar.displayText = tab.displayHost
                self?.tabSidebar.fauxAddressBar.isSecure = url?.scheme == "https" || url == nil
                self?.tabSidebar.reloadButton.isEnabled = url != nil
            }
            .store(in: &displayTabSubscriptions)

        tab.$isLoading
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isLoading in
                self?.tabSidebar.updateReloadButton(isLoading: isLoading)
            }
            .store(in: &displayTabSubscriptions)

        tab.$canGoBack
            .receive(on: RunLoop.main)
            .sink { [weak self] canGoBack in
                if self?.selectedTab?.peekTab != nil {
                    self?.tabSidebar.backButton.isEnabled = canGoBack
                } else {
                    let canCloseToParent = !canGoBack && self?.parentTab(for: tab) != nil
                    self?.tabSidebar.backButton.isEnabled = canGoBack || canCloseToParent
                }
            }
            .store(in: &displayTabSubscriptions)

        tab.$canGoForward
            .receive(on: RunLoop.main)
            .sink { [weak self] canGoForward in
                self?.tabSidebar.forwardButton.isEnabled = canGoForward
            }
            .store(in: &displayTabSubscriptions)
    }

    // MARK: - Window Events

    @objc private func handleContentBlockerRulesChanged() {
        guard let tab = selectedTab, ownsWebView,
              let profile = activeSpace?.profile else { return }

        // Remove old rule lists and re-add current ones — on every owned pane
        for member in splitMembers(of: tab) {
            guard let webView = member.webView else { continue }
            let ucc = webView.configuration.userContentController
            ucc.removeAllContentRuleLists()
            ContentBlockerManager.shared.applyRuleLists(to: ucc, profile: profile)
        }
    }

    @objc private func handleWebViewOwnershipChanged(_ notification: Notification) {
        guard let sender = notification.object as? BrowserWindowController, sender !== self,
              let tab = selectedTab else { return }
        // Another window claiming any pane of our selected tab's group takes
        // the whole hosted view with it — two windows showing the same split
        // may focus different members, so match on group membership, not the
        // single focused tabID.
        let claimedIDs = notification.userInfo?["tabIDs"] as? [UUID]
            ?? (notification.userInfo?["tabID"] as? UUID).map { [$0] } ?? []
        guard !Set(splitMembers(of: tab).map(\.id)).isDisjoint(with: claimedIDs) else { return }

        // The sender has already reparented the container by the time this
        // notification arrives, so `ownsWebView` is already false here. "We
        // were the owner" ⟺ we were displaying live content, not a snapshot.
        if snapshotImageView == nil {
            // Hide peek UI before losing ownership
            hidePeekUI()

            if let image = notification.userInfo?["snapshot"] as? NSImage {
                localSnapshot = image
            }
            showSnapshot(for: tab)
        }
    }

    @objc private func handleExtensionTabShouldSelect(_ notification: Notification) {
        guard let info = notification.userInfo,
              let tabID = info["tabID"] as? UUID,
              let spaceID = info["spaceID"] as? UUID else { return }
        // Only handle if this window owns the space
        guard activeSpaceID == spaceID else { return }
        selectTab(id: tabID)
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

    /// A URL the input denotes directly (explicit scheme or host-like); nil when
    /// the input is a search phrase.
    func directURL(from input: String) -> URL? {
        if input.hasPrefix("http://") || input.hasPrefix("https://") {
            return URL(string: input)
        }
        if input.contains(".") && !input.contains(" ") {
            return URL(string: "https://\(input)")
        }
        return nil
    }

    func urlFromInput(_ input: String) -> URL? {
        if let url = directURL(from: input) { return url }
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
        guard let urlString = displayTab?.url?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
        toastManager.show(message: "URL copied")
    }

    @objc func reloadPage(_ sender: Any?) {
        if let peek = selectedTab?.peekTab {
            peek.webView?.reload()
            return
        }
        ensureOwnsWebView()
        selectedTab?.reload()
    }

    @objc func zoomIn(_ sender: Any?) {
        guard let webView = selectedTab?.webView else { return }
        webView.pageZoom = min(webView.pageZoom + 0.1, 3.0)
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let webView = selectedTab?.webView else { return }
        webView.pageZoom = max(webView.pageZoom - 0.1, 0.3)
    }

    @objc func zoomActualSize(_ sender: Any?) {
        guard let webView = selectedTab?.webView else { return }
        webView.pageZoom = 1.0
    }

    @objc func goBack(_ sender: Any?) {
        navigateBackOrCloseChildTab()
    }

    private func parentTab(for tab: BrowserTab) -> BrowserTab? {
        guard let parentID = tab.parentID else { return nil }
        return currentTabs.first { $0.id == parentID }
            ?? activeSpace?.pinnedEntries.compactMap(\.tab).first { $0.id == parentID }
    }

    func navigateBackOrCloseChildTab() {
        if let peek = selectedTab?.peekTab {
            peek.webView?.goBack()
            return
        }
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
        if let peek = selectedTab?.peekTab {
            peek.webView?.goForward()
            return
        }
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
        if let palette = commandPaletteView {
            if palette.isAnchored {
                commandPaletteNavigatesInPlace = false
                palette.switchToCentered()
            } else {
                dismissCommandPalette()
            }
            return
        }
        commandPaletteNavigatesInPlace = false
        showCommandPalette()
    }

    @objc func focusAddressBar(_ sender: Any?) {
        // When peek is open, show peek URL but open a new tab (like Cmd+T)
        commandPaletteNavigatesInPlace = selectedTab?.peekTab == nil
        showCommandPalette(initialText: displayTab?.url?.absoluteString)
    }

    func showCommandPalette(initialText: String? = nil, anchorFrame: NSRect? = nil) {
        guard commandPaletteView == nil else { return }
        let palette = CommandPaletteView()
        palette.delegate = self
        palette.tabStore = store
        palette.activeSpaceID = activeSpaceID
        palette.currentTabID = selectedTab?.id
        palette.profile = activeSpace?.profile
        commandPaletteView = palette

        // Two scrims: the liquid glass sidebar is partially transparent, so we need
        // one behind the sidebar (on splitViewController.view) and one above the
        // content (on contentContainerView).
        let splitScrim = NSView()
        splitScrim.wantsLayer = true
        splitScrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
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
            contentScrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
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
        // Return focus to the peek webview so keys go to it, not the tab behind
        if peekOverlayView != nil, let peekWebView = selectedTab?.peekTab?.webView {
            window?.makeFirstResponder(peekWebView)
        }
    }

    func deselectAllTabs() {
        removeSplitRevealOverlay()
        selectedTabID = nil
        activeSpace?.selectedTabID = nil
        activeTabSubscriptions.removeAll()
        displayTabSubscriptions.removeAll()
        hidePeekUI()
        dragHandle.isHidden = true
        removeContentViews()
        let hasTabs = !(activeSpace?.tabs.isEmpty ?? true) || !(activeSpace?.pinnedEntries.isEmpty ?? true)
        emptyStateLabel.stringValue = hasTabs ? "Where to next?" : "A rare moment of tab peace."
        emptyStateLabel.isHidden = false
        tabSidebar.fauxAddressBar.displayText = ""
        tabSidebar.fauxAddressBar.isSecure = true
        tabSidebar.backButton.isEnabled = false
        tabSidebar.forwardButton.isEnabled = false
        tabSidebar.reloadButton.isEnabled = false
        tabSidebar.tableView.deselectAll(nil)
        tabSidebar.updateFavoriteSelection(selectedTabID: nil)
        window?.title = "Detour"
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        // If peek overlay is showing, dismiss it instead of closing the tab
        if peekOverlayView != nil {
            closePeekOverlay()
            return
        }

        guard let id = selectedTabID else {
            window?.performClose(sender)
            return
        }

        guard let space = activeSpace else { return }

        // Check if it's a pinned entry
        if let index = space.pinnedEntries.firstIndex(where: { $0.tab?.id == id }) {
            closePinnedTab(at: index)
            return
        }

        // Favorite-backed tabs live only in profile.favorites (not space.tabs or
        // pinnedEntries); closing one discards its backing tab and deselects.
        if let profile = space.profile,
           let fav = profile.favorites.first(where: { $0.tab?.id == id }) {
            store.deactivateFavorite(id: fav.id, profileID: profile.id)
            deselectAllTabs()
            return
        }

        let tabs = currentTabs
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        closeTab(at: index, wasSelected: true)
    }

    func closePinnedTab(at index: Int) {
        guard let space = activeSpace, index < space.pinnedEntries.count else { return }
        let entry = space.pinnedEntries[index]
        // Settle selection BEFORE discarding the backing tab, mirroring
        // closeTab(at:wasSelected:). Closing the focused pane of a pinned split
        // leaves its still-live partner on screen, so select the partner rather
        // than blanking the window — closePinnedTab keeps the group intact (the
        // closed member just goes dormant). Otherwise deselect.
        if let groupID = entry.splitGroupID,
           let partnerTab = store.pinnedSplitEntries(groupID: groupID, in: space)
               .first(where: { $0.id != entry.id })?.tab {
            selectTab(id: partnerTab.id)
        } else {
            deselectAllTabs()
        }
        // Always make dormant (discard backing tab)
        store.closePinnedTab(id: entry.id, in: space)
    }

    func closeTab(at index: Int, wasSelected: Bool) {
        guard let space = activeSpace else { return }
        let tabs = currentTabs
        guard index >= 0, index < tabs.count else { return }

        // Settle selection BEFORE removing the tab so the removal observer
        // (tabStoreDidRemoveTab) sees selection already moved off the closing
        // tab and doesn't also try to advance it.
        // Closing a split pane (Cmd+W closes the focused pane, not the row)
        // stays in the split: the surviving partner wins over the generic
        // adjacent-tab fallback.
        if wasSelected,
           let group = store.splitGroup(containing: tabs[index].id, in: space),
           let partner = group.members.first(where: { $0.id != tabs[index].id }) {
            selectTab(id: partner.id)
        } else if wasSelected {
            let nextID: UUID? = tabCloseSelectionID(
                closingIndex: index,
                tabs: tabs.map { ($0.id, $0.parentID) },
                pinnedTabIDs: Set(space.pinnedEntries.compactMap { $0.tab?.id })
            )
            if let nextID { selectTab(id: nextID) }
            else if let firstLiveEntry = space.pinnedEntries.first(where: { $0.tab != nil }),
                    let tab = firstLiveEntry.tab { selectTab(id: tab.id) }
            else if let firstDormantEntry = space.pinnedEntries.first {
                store.activatePinnedEntry(id: firstDormantEntry.id, in: space)
                if let tab = firstDormantEntry.tab { selectTab(id: tab.id) }
                else { deselectAllTabs() }
            }
            else { deselectAllTabs() }
        }

        store.closeTab(id: tabs[index].id, in: space)
    }

    // MARK: - Pin/Unpin

    @objc func togglePinTab(_ sender: Any?) {
        guard !isIncognito else { return }
        guard let tab = selectedTab, let space = activeSpace else { return }
        if let entry = space.pinnedEntries.first(where: { $0.tab?.id == tab.id }) {
            store.unpinTab(id: entry.id, in: space)
            selectTab(id: tab.id)
        } else {
            guard tab.url != nil else { return }
            store.pinTab(id: tab.id, in: space)
            selectTab(id: tab.id)
        }
    }

    // MARK: - Peek Overlay

    // Esc handling for the peek lives here, not on PeekOverlayView: the peek
    // webview holds first responder, and key events the page declines bubble
    // up the webview's responder chain (contentContainerView → window → this
    // controller). Pages that consume Esc — closing a site modal, exiting
    // fullscreen — still win, because WebKit only re-dispatches unhandled
    // events. Depending on how AppKit interprets the event it arrives as a
    // raw keyDown or as cancelOperation, so both are overridden.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, peekOverlayView != nil { // Esc
            closePeekOverlay()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if peekOverlayView != nil {
            closePeekOverlay()
        }
    }

    private func hidePeekUI() {
        guard peekOverlayView != nil else { return }
        peekTabSubscriptions.removeAll()
        if let peekWebView = selectedTab?.peekTab?.webView {
            // Symmetric with claimPeekWebView: drop the userContentController's
            // strong reference to this controller while the peek is hidden —
            // the next present re-claims it, possibly from another window.
            peekWebView.configuration.userContentController.removeScriptMessageHandler(forName: BlockedResourceTracker.messageName)
            if peekWebView !== pipContentView {
                peekWebView.removeFromSuperview()
            }
        }
        peekOverlayView?.removeFromSuperview()
        peekOverlayView = nil
        displayTabSubscriptions.removeAll()
        bindDisplayTab()
    }

    private func claimPeekWebView(_ webView: WKWebView) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.configuration.userContentController.removeScriptMessageHandler(forName: BlockedResourceTracker.messageName)
        webView.configuration.userContentController.add(self, name: BlockedResourceTracker.messageName)
    }

    /// Re-presents the selected tab's peek overlay after it was hidden (tab
    /// switch, webview ownership loss, window refocus). Reuses the live peek
    /// tab when one exists — recreating from `peekURL` would discard in-peek
    /// navigation history — and otherwise rebuilds from persisted state.
    private func restorePeekOverlayIfNeeded() {
        guard peekOverlayView == nil, let tab = selectedTab else { return }
        if let existingPeek = tab.peekTab, let peekWebView = existingPeek.webView {
            claimPeekWebView(peekWebView)
            presentPeekWebView(peekWebView, clickPoint: nil, animate: false)
            observePeekTab(existingPeek, for: tab)
        } else if let peekURL = tab.peekURL {
            showPeekOverlay(url: peekURL, clickPoint: nil, interactionState: tab.peekInteractionState)
        }
    }

    /// Mirrors live peek-tab state onto the host tab. Without the URL sink,
    /// `peekURL`/`peekInteractionState` hold open-time values until the next
    /// sleep or window close, so mid-session saves would restore the peek to
    /// the page it was opened at rather than where the user navigated.
    private func observePeekTab(_ peekTab: BrowserTab, for host: BrowserTab) {
        peekTabSubscriptions.removeAll()

        peekTab.$favicon
            .dropFirst()
            .removeDuplicates(by: ===)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak host] _ in
                host?.peekFaviconURL = peekTab.faviconURL
                self?.reloadSelectedTabSidebarCell()
            }
            .store(in: &peekTabSubscriptions)

        peekTab.$url
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak host] url in
                guard let host, url != nil else { return }
                host.savePeekStateForPersistence()
                self?.store.scheduleSave()
            }
            .store(in: &peekTabSubscriptions)
    }

    private func reloadSelectedTabSidebarCell() {
        guard let selectedTabID, let space = activeSpace else { return }
        if let pinnedIdx = space.pinnedEntries.firstIndex(where: { $0.tab?.id == selectedTabID }) {
            tabSidebar.reloadPinnedEntry(at: pinnedIdx)
        } else if let tabIdx = space.tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabSidebar.reloadTab(at: tabIdx)
        }
    }

    func showPeekOverlay(url: URL, clickPoint: CGPoint? = nil, interactionState: Data? = nil) {
        guard let tab = selectedTab, let space = activeSpace else { return }

        if let existingPeek = tab.peekTab, let peekWebView = existingPeek.webView {
            if existingPeek.url != url {
                closePeekOverlay()
            } else {
                hidePeekUI()
                claimPeekWebView(peekWebView)
                presentPeekWebView(peekWebView, clickPoint: clickPoint, animate: true)
                observePeekTab(existingPeek, for: tab)
                return
            }
        }

        hidePeekUI()

        let config = space.makeWebViewConfiguration()
        let newPeekTab = BrowserTab(configuration: config)
        guard let peekWebView = newPeekTab.webView else { return }
        claimPeekWebView(peekWebView)
        peekWebView.allowsBackForwardNavigationGestures = true
        tab.peekTab = newPeekTab
        reloadSelectedTabSidebarCell()

        observePeekTab(newPeekTab, for: tab)

        presentPeekWebView(peekWebView, clickPoint: clickPoint, animate: true)

        // Restore from interaction state if available, otherwise load URL
        if let interactionState,
           let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: interactionState) {
            unarchiver.requiresSecureCoding = false
            if let state = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) {
                peekWebView.interactionState = state
            } else {
                peekWebView.load(URLRequest(url: url))
            }
        } else {
            peekWebView.load(URLRequest(url: url))
        }

        tab.peekURL = url
        store.scheduleSave()
    }

    /// Sets up peek overlay chrome and adds the peek webview to the view hierarchy.
    private func presentPeekWebView(_ peekWebView: WKWebView, clickPoint: CGPoint?, animate: Bool) {
        let overlay = PeekOverlayView(clickPoint: clickPoint)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onClose = { [weak self] in
            self?.closePeekOverlay()
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

        if animate {
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
        }

        peekOverlayView = overlay
        bindDisplayTab()

        // Focus the peek so keyboard input (space, arrows, Esc) targets it
        // immediately instead of the tab's webview behind the overlay.
        window?.makeFirstResponder(peekWebView)
    }

    /// Closes and destroys the peek tab. Used when the user explicitly dismisses.
    private func closePeekOverlay() {
        guard let overlay = peekOverlayView else { return }
        let tab = selectedTab
        let peekTab = tab?.peekTab
        peekTab?.webView?.configuration.userContentController.removeScriptMessageHandler(forName: BlockedResourceTracker.messageName)
        peekTabSubscriptions.removeAll()
        tab?.clearPeekState()
        reloadSelectedTabSidebarCell()
        store.scheduleSave()
        peekOverlayView = nil
        bindDisplayTab()
        overlay.animateClose {
            overlay.removeFromSuperview()
        }
        // Fade out the webview, then tear the peek tab down like any other
        // closed tab (pauses media, removes observers, releases the webview).
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            peekTab?.webView?.alphaValue = 0
        }, completionHandler: {
            peekTab?.teardown()
        })
        // Safety net: tear down even if animation completion doesn't fire
        // (teardown is idempotent)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak overlay] in
            overlay?.removeFromSuperview()
            peekTab?.teardown()
        }
        // Restore first responder to the web view
        if let webView = tab?.webView {
            window?.makeFirstResponder(webView)
        }
    }

    private func expandPeekToNewTab() {
        guard let overlay = peekOverlayView,
              let webView = selectedTab?.peekTab?.webView,
              let space = activeSpace else {
            closePeekOverlay()
            return
        }

        // Clear peek state on original tab
        peekTabSubscriptions.removeAll()
        selectedTab?.clearPeekState()
        reloadSelectedTabSidebarCell()
        store.scheduleSave()

        displayTabSubscriptions.removeAll()

        // Create tab with the existing webview
        let tab = store.addTab(in: space, webView: webView, parentID: selectedTabID)

        // Clear peek references so selectTab won't double-dismiss
        peekOverlayView = nil

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

}

// MARK: - NSMenuItemValidation

extension BrowserWindowController: NSMenuItemValidation {
    @objc func browserUndo(_ sender: Any?) {
        store.undoManager.undo()
    }

    @objc func browserRedo(_ sender: Any?) {
        store.undoManager.redo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(browserUndo(_:)) {
            if let webView = selectedTab?.webView as? BrowserWebView, webView.isEditingWebContent {
                menuItem.title = "Undo"
                return true
            }
            menuItem.title = store.undoManager.undoMenuItemTitle
            return store.undoManager.canUndo
        }
        if menuItem.action == #selector(browserRedo(_:)) {
            if let webView = selectedTab?.webView as? BrowserWebView, webView.isEditingWebContent {
                menuItem.title = "Redo"
                return true
            }
            menuItem.title = store.undoManager.redoMenuItemTitle
            return store.undoManager.canRedo
        }
        if menuItem.action == #selector(reopenClosedTab(_:)) {
            guard let space = activeSpace else { return false }
            return store.canReopenClosedTab(in: space)
        }
        if menuItem.action == #selector(togglePinTab(_:)) {
            guard let tab = selectedTab else { return false }
            if isIncognito { return false }
            let isPinned = activeSpace?.pinnedEntries.contains(where: { $0.tab?.id == tab.id }) ?? false
            menuItem.title = isPinned ? "Unpin Tab" : "Pin Tab"
            if !isPinned && tab.url == nil { return false }
            return true
        }
        if menuItem.action == #selector(nextSpace(_:)) {
            return !isIncognito && canNavigateSpace(offset: 1)
        }
        if menuItem.action == #selector(previousSpace(_:)) {
            return !isIncognito && canNavigateSpace(offset: -1)
        }
        if menuItem.action == #selector(selectSpaceFromMenu(_:))
            || menuItem.action == #selector(openSpacesSettings(_:)) {
            return !isIncognito
        }
        return true
    }
}

/// Click-through container for the split-formation veneer — purely visual, it
/// must never intercept events destined for the live panes beneath it.
private final class ClickThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Split view hosting a split tab pair. The divider is an invisible
/// `splitPaneGap`-thick strip so the rounded pane cards sit visually apart;
/// it also gives the resize cursor a wider grab area than a thin divider.
private final class HostedSplitView: NSSplitView {
    /// The focused-pane border color is appearance-dependent (black/white) and
    /// baked into the layer as a CGColor — re-derive it on light/dark switches.
    var onEffectiveAppearanceChange: (() -> Void)?

    override var dividerThickness: CGFloat { UIConstants.splitPaneGap }
    override func drawDivider(in rect: NSRect) {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }
}

// MARK: - NSSplitViewDelegate (hosted split tabs)

// Delegate for `hostedSplitView` only — the window's sidebar/content split is
// managed by its own NSSplitViewController. Guard every method on identity.
extension BrowserWindowController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === hostedSplitView else { return proposedMinimumPosition }
        return (splitView.bounds.width - splitView.dividerThickness) * 0.2
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === hostedSplitView else { return proposedMaximumPosition }
        return (splitView.bounds.width - splitView.dividerThickness) * 0.8
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let split = notification.object as? NSSplitView,
              split === hostedSplitView else { return }
        updateSplitPaneShadowPaths()
        guard !isApplyingSplitLayout else { return }
        // A fraction claimed before the split had geometry gets applied on the
        // first real layout — committing here would persist the 50/50 default.
        if let pending = pendingSplitFraction {
            applySplitFraction(pending, to: split)
            return
        }
        // Self-repair: the panes must tile the split's bounds. If a frame-
        // history bug ever leaves a pane collapsed or the pair short of the
        // full width (a dead white region), re-apply the stored fraction —
        // applySplitFraction frames both panes explicitly — instead of
        // committing the broken geometry as the new fraction.
        if panesAreMistiled(in: split) {
            let fraction = activeSpace.flatMap { space in
                selectedTab.flatMap { store.splitFraction(containing: $0.id, in: space) }
            } ?? 0.5
            applySplitFraction(fraction, to: split)
            return
        }
        scheduleSplitFractionCommit(for: split)
    }

    /// Whether the two panes fail to tile the split view: a collapsed pane or
    /// uncovered width. The 1pt tolerance keeps ordinary resize rounding from
    /// ever triggering a repair.
    private func panesAreMistiled(in split: NSSplitView) -> Bool {
        let panes = split.arrangedSubviews
        guard panes.count == 2 else { return false }
        let covered = panes[0].frame.width + panes[1].frame.width + split.dividerThickness
        return abs(covered - split.bounds.width) > 1
            || panes[0].frame.width < 1 || panes[1].frame.width < 1
    }

    /// Debounced divider→model write: no undo, save-only (via setSplitFraction).
    /// Window resizes keep proportions, so the recomputed fraction matches the
    /// stored one and the unchanged-guard skips those. The group is resolved at
    /// schedule time so a flush during content teardown (when selection may
    /// already have moved) still writes to the right group.
    private func scheduleSplitFractionCommit(for split: NSSplitView) {
        let available = split.bounds.width - split.dividerThickness
        // Two live panes required: a mid-teardown split (a pinned member going
        // dormant pulls its container out, stretching the survivor to full
        // width) would otherwise commit that stretch as the group's fraction —
        // the pinned group outlives the dormant member, so splitGroup still
        // resolves here.
        guard available > 0, split.arrangedSubviews.count == 2,
              let leftPane = split.arrangedSubviews.first,
              let space = activeSpace, let tab = selectedTab,
              let group = store.splitGroup(containing: tab.id, in: space) else { return }
        // Cancel before the unchanged-guard: dragging away and back to the
        // stored fraction must also drop the stale in-between commit.
        splitFractionCommit?.cancel()
        splitFractionCommit = nil

        let fraction = Double(leftPane.frame.width / available)
        let stored = store.splitFraction(containing: tab.id, in: space) ?? 0.5
        guard abs(stored - fraction) > 0.001 else { return }

        let groupID = group.groupID
        // Clear the slot as we fire so a later flush/close doesn't re-perform()
        // this already-committed fraction over a newer value. Unconditional is
        // safe: on the serial main queue a superseded item is cancelled before
        // it can run, and the flush path nils the slot before perform().
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.splitFractionCommit = nil
            self.store.setSplitFraction(groupID: groupID, fraction: fraction, in: space)
        }
        splitFractionCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

// MARK: - NSWindowDelegate

extension BrowserWindowController: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        // Update extension manager's active space for chrome.tabs.query({currentWindow: true})
        if let spaceID = activeSpaceID {
            ExtensionManager.shared.lastActiveSpaceID = spaceID
        }

        if let tab = selectedTab {
            claimWebView(for: tab)
            // Restore peek overlay if the tab has one and we don't already
            // have it showing. Goes through the shared restore path so a live
            // peek (possibly navigated away from `peekURL`) is reused rather
            // than destroyed and recreated at its opening URL.
            restorePeekOverlayIfNeeded()
        }
    }

    /// The reveal veneer's cards animate toward pane frames captured at
    /// install; a resize mid-animation would leave them misaligned over the
    /// retiled panes, so drop the (purely cosmetic) veneer instead.
    func windowDidResize(_ notification: Notification) {
        removeSplitRevealOverlay()
    }

    // The hosted split's chrome differs between windowed (inset rounded
    // cards) and fullscreen (full bleed, square) — re-derive on transitions.
    func windowDidEnterFullScreen(_ notification: Notification) {
        refreshHostedSplitChromeForFullScreenChange()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        refreshHostedSplitChromeForFullScreenChange()
    }

    private func refreshHostedSplitChromeForFullScreenChange() {
        guard let split = hostedSplitView else { return }
        split.frame = hostedSplitFrame
        updateSplitPaneFocus()
    }

    func windowWillClose(_ notification: Notification) {
        selectedTab?.savePeekStateForPersistence()
        hidePeekUI()
        // Detach the script message handlers we added to the owned web view's
        // userContentController. add(self, name:) retains this controller, so
        // without this the controller (and its notification observers) leak and
        // a zombie window can keep reacting to tab notifications after close.
        releaseOwnedWebViewHandlers()
        flushPendingSplitFractionCommit()
        store.saveNow()
        store.removeObserver(self)
        NotificationCenter.default.removeObserver(self)

        if isIncognito, let spaceID = incognitoSpaceID {
            store.removeIncognitoSpace(id: spaceID)
        }
    }

    /// Remove the script message handlers this controller registered on the
    /// currently-owned tab's web view, breaking the userContentController's
    /// strong reference to `self`.
    private func releaseOwnedWebViewHandlers() {
        guard ownsWebView, let tab = selectedTab else { return }
        for member in splitMembers(of: tab) {
            guard let webView = member.webView else { continue }
            let ucc = webView.configuration.userContentController
            for name in Self.ownedScriptHandlerNames {
                ucc.removeScriptMessageHandler(forName: name)
            }
            (webView as? BrowserWebView)?.isEditingWebContent = false
        }
    }
}



// MARK: - CommandPaletteDelegate

extension BrowserWindowController: CommandPaletteDelegate {
    func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String) {
        if let url = directURL(from: input) {
            paletteLoadURL(url, typed: true)
        } else {
            let engine = activeSpace?.profile?.searchEngine ?? .google
            guard let url = engine.searchURL(for: input) else { return }
            paletteLoadURL(url, typed: false)
        }
    }

    func commandPalette(_ palette: CommandPaletteView, didSubmitSearch query: String) {
        let engine = activeSpace?.profile?.searchEngine ?? .google
        guard let url = engine.searchURL(for: query) else { return }
        paletteLoadURL(url, typed: false)
    }

    private func paletteLoadURL(_ url: URL, typed: Bool) {
        let navigateInPlace = commandPaletteNavigatesInPlace
        dismissCommandPalette()

        if navigateInPlace, let tab = selectedTab {
            ensureOwnsWebView()
            tab.load(url, typed: typed)
        } else {
            guard let space = activeSpace else { return }
            let tab = store.addTab(in: space)
            selectTab(id: tab.id)
            tab.load(url, typed: typed)
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
        if message.name == "linkHover", let urlString = message.body as? String {
            if urlString.isEmpty {
                linkStatusBar.hide()
            } else {
                linkStatusBar.show(url: urlString)
            }
        } else if message.name == "editableFieldFocus", let editing = message.body as? Bool {
            if let webView = message.webView as? BrowserWebView {
                webView.isEditingWebContent = editing
            }
        } else if message.name == BlockedResourceTracker.messageName, let count = message.body as? Int {
            if let peek = selectedTab?.peekTab, message.webView == peek.webView {
                peek.blockedCount = count
            } else if let tab = selectedTab,
                      let member = splitMembers(of: tab).first(where: { $0.webView === message.webView }) {
                // In a split, the message may come from the unfocused pane.
                member.blockedCount = count
            } else {
                selectedTab?.blockedCount = count
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

