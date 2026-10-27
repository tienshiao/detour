import AppKit
import WebKit

// MARK: - SettingsWindowController

class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private static let generalID = NSToolbarItem.Identifier("general")
    private static let spacesID = NSToolbarItem.Identifier("spaces")
    private static let linksID = NSToolbarItem.Identifier("links")
    private static let quickDetourID = NSToolbarItem.Identifier("quickdetour")
    private static let profilesID = NSToolbarItem.Identifier("profiles")
    private static let extensionsID = NSToolbarItem.Identifier("extensions")
    private static let contentBlockerID = NSToolbarItem.Identifier("contentblocker")

    private var panes: [NSToolbarItem.Identifier: SettingsPaneViewController] = [:]
    /// The toolbar's panes, in order.
    static let paneOrder: [NSToolbarItem.Identifier] = [
        generalID, spacesID, linksID, quickDetourID, profilesID, extensionsID, contentBlockerID,
    ]

    /// Replaces the height of the screen's visible frame in the height rule,
    /// so a harness can exercise the cap on a tall screen. Nil in the app.
    var screenUsableHeightOverride: CGFloat?

    /// The fit last applied to the window, which `refit` starts from.
    private var currentFit: SettingsPaneHeight?
    /// The content height an animation in flight is heading to. A refit that
    /// arrives mid-animation (a pane reporting its rows from `viewWillAppear`)
    /// starts from this, not from the window's intermediate height.
    private var animationTargetHeight: CGFloat?

    private init() {
        // Resizable in height only (TASK-189): the minimum and maximum content
        // widths are both the window's width, and each pane sets the heights.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.windowWidth, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Settings"
        window.toolbarStyle = .preference
        window.collectionBehavior.insert(.fullScreenNone)
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: SettingsMetrics.windowWidth, height: 200)
        window.contentMaxSize = NSSize(width: SettingsMetrics.windowWidth, height: 200)
        window.center()

        super.init(window: window)

        let generalVC = GeneralSettingsViewController()
        panes[Self.generalID] = generalVC

        let spacesVC = SpacesSettingsViewController()
        panes[Self.spacesID] = spacesVC

        let linksVC = LinksSettingsViewController()
        panes[Self.linksID] = linksVC

        panes[Self.quickDetourID] = QuickDetourSettingsViewController()

        let profilesVC = ProfilesSettingsViewController()
        panes[Self.profilesID] = profilesVC

        let extensionsVC = ExtensionsSettingsViewController()
        panes[Self.extensionsID] = extensionsVC

        let contentBlockerVC = ContentBlockerSettingsViewController()
        panes[Self.contentBlockerID] = contentBlockerVC

        for pane in panes.values {
            pane.onContentHeightChange = { [weak self, weak pane] in
                guard let self, let pane, self.window?.contentViewController === pane else { return }
                self.fitWindow(to: pane, animate: true, refitting: true)
            }
        }

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = Self.generalID
        window.toolbar = toolbar

        window.contentViewController = generalVC

        // The cap follows the screen the window is on: moving it to a shorter
        // display, a resolution change or an unplugged display re-fits it.
        NotificationCenter.default.addObserver(self, selector: #selector(screenDidChange),
                                               name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(screenDidChange),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screenDidChange() {
        guard let window, window.isVisible,
              let pane = window.contentViewController as? SettingsPaneViewController else { return }
        fitWindow(to: pane, animate: true, refitting: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        let wasVisible = window?.isVisible ?? false
        super.showWindow(sender)
        if !wasVisible, let pane = window?.contentViewController as? SettingsPaneViewController {
            fitWindow(to: pane, animate: false, refitting: false)
        }
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case Self.generalID:
            item.label = "General"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        case Self.spacesID:
            item.label = "Spaces"
            item.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Spaces")
        case Self.linksID:
            item.label = "Links"
            item.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Links")
        case Self.quickDetourID:
            // A window over another: Quick Detour opens over the app in front.
            item.label = QuickDetour.displayName
            item.image = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                 accessibilityDescription: QuickDetour.displayName)
        case Self.profilesID:
            item.label = "Profiles"
            item.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Profiles")
        case Self.extensionsID:
            item.label = "Extensions"
            item.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Extensions")
        case Self.contentBlockerID:
            item.label = "Content Blocking"
            item.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "Content Blocking")
        default:
            return nil
        }
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.paneOrder
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.paneOrder
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.paneOrder
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let vc = panes[sender.itemIdentifier] else { return }
        switchToPane(vc, identifier: sender.itemIdentifier)
    }

    /// Programmatically show the Spaces pane, optionally selecting a space by ID.
    func showSpacesPane(selectSpaceID: UUID? = nil) {
        showWindow(nil)
        guard let vc = panes[Self.spacesID] as? SpacesSettingsViewController else { return }
        if let spaceID = selectSpaceID {
            vc.selectSpace(id: spaceID)
        }
        switchToPane(vc, identifier: Self.spacesID)
    }

    /// Shows the Links pane (Link Routes, TASK-191.3). With a space,
    /// the routes and the Default that target it are highlighted and the
    /// first is scrolled into view: the blocked-deletion alert opens it so.
    func showLinksPane(highlightingSpaceID spaceID: UUID? = nil) {
        showWindow(nil)
        guard let vc = panes[Self.linksID] as? LinksSettingsViewController else { return }
        vc.highlightRoutes(targetingSpaceID: spaceID)
        switchToPane(vc, identifier: Self.linksID)
    }

    /// Programmatically show the Extensions pane.
    func showExtensionsPane() {
        showWindow(nil)
        guard let vc = panes[Self.extensionsID] else { return }
        switchToPane(vc, identifier: Self.extensionsID)
    }

    private func switchToPane(_ vc: SettingsPaneViewController, identifier: NSToolbarItem.Identifier) {
        guard let window else { return }
        window.toolbar?.selectedItemIdentifier = identifier
        guard window.contentViewController !== vc else {
            // Re-selecting the shown pane keeps a height the user dragged to.
            fitWindow(to: vc, animate: true, refitting: true)
            return
        }
        // Swap at the current size so the window does not jump to the new
        // pane's last frame, then animate to the new pane's height.
        let frame = window.frame
        vc.view.setFrameSize(window.contentLayoutRect.size)
        window.contentViewController = vc
        window.setFrame(frame, display: false)
        fitWindow(to: vc, animate: true, refitting: false)
    }

    /// Sizes the window to `pane` by the height rule and sets the bounds the
    /// user can drag it within. The top edge stays put; the window moves up
    /// only as far as needed to stay on screen.
    private func fitWindow(to pane: SettingsPaneViewController, animate: Bool, refitting: Bool) {
        guard let window else { return }
        window.layoutIfNeeded()
        let chrome = window.frame.height - window.contentLayoutRect.height
        let fit = SettingsPaneHeight.fit(natural: pane.naturalContentHeight,
                                         minimum: pane.minimumContentHeight,
                                         screenUsableHeight: screenUsableHeightOverride
                                            ?? Self.screen(of: window)?.visibleFrame.height ?? 800,
                                         chromeHeight: chrome)
        let current = animationTargetHeight ?? window.contentLayoutRect.height
        let height: CGFloat
        if refitting, let old = currentFit {
            height = SettingsPaneHeight.refit(current: current, from: old, to: fit)
        } else {
            height = fit.initial
        }
        currentFit = fit
        // The new bounds go on after the animation: a max below the current
        // height (or a min above it) would snap the window there at once.
        // During it, the bounds only widen to cover where the window is now.
        let actual = window.contentLayoutRect.height
        window.contentMinSize = NSSize(width: SettingsMetrics.windowWidth, height: min(fit.minHeight, actual))
        window.contentMaxSize = NSSize(width: SettingsMetrics.windowWidth, height: max(fit.maxHeight, actual))

        let old = window.frame
        var frame = NSRect(x: old.minX, y: old.maxY - height - chrome,
                           width: SettingsMetrics.windowWidth, height: height + chrome)
        if let visible = Self.screen(of: window)?.visibleFrame {
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
            if frame.minY < visible.minY { frame.origin.y = min(visible.minY, visible.maxY - frame.height) }
        }
        let finish = { [weak self] in
            // A later fit (another switch mid-animation) owns the bounds.
            guard let self, self.currentFit == fit, window.contentViewController === pane,
                  self.animationTargetHeight == nil || self.animationTargetHeight == height else { return }
            self.animationTargetHeight = nil
            window.contentMinSize = NSSize(width: SettingsMetrics.windowWidth, height: fit.minHeight)
            window.contentMaxSize = NSSize(width: SettingsMetrics.windowWidth, height: fit.maxHeight)
            pane.paneDidFit()
        }
        guard frame != old else {
            animationTargetHeight = nil
            return finish()
        }
        if animate && window.isVisible {
            animationTargetHeight = height
            // Asynchronous (the animator proxy), so the switch returns at
            // once; a refit that lands mid-animation starts from the target.
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = window.animationResizeTime(frame)
                window.animator().setFrame(frame, display: true)
            }, completionHandler: finish)
        } else {
            animationTargetHeight = nil
            window.setFrame(frame, display: true)
            finish()
        }
    }

    /// The screen the window is on, else the main screen.
    private static func screen(of window: NSWindow) -> NSScreen? {
        window.screen ?? NSScreen.main
    }
}
