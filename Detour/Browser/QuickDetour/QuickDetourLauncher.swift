import AppKit

/// The palette that opens a Quick Detour, alone in a panel like Spotlight
/// (TASK-193.1, as changed by the user on 2026-10-25): no web view, no title
/// bar. Submitting — a URL, a search, a suggestion — closes the panel and
/// opens the Quick Detour window loading the page; Escape or clicking away
/// (the panel resigning key) closes it and nothing opens. So no Quick Detour
/// window ever exists with an empty page.
///
/// One panel at a time: asking again while it is up brings it forward, or
/// rebuilds it when the profile differs.
///
/// Built for TASK-193.2's global hotkey too: the panel is non-activating, so
/// it takes the keyboard while another app stays frontmost, and it does not
/// hide when Detour is not active. Detour is activated only when a page is
/// submitted, for the window that opens.
final class QuickDetourLauncher: NSObject {
    static let shared = QuickDetourLauncher()

    private(set) var panel: QuickDetourPalettePanel?
    private(set) var profile: Profile?
    private var sourceSpaceID: UUID?
    private var resignObserver: NSObjectProtocol?

    /// What submitting does: opens the window. Replaced by tests.
    var openWindow: @MainActor (_ profile: Profile, _ sourceSpace: Space?, _ url: URL, _ typed: Bool) -> Void = defaultOpenWindow

    /// Opens the window, then activates Detour, for the panel the global
    /// hotkey showed over another app (TASK-193.2). Only the Quick Detour
    /// window comes forward: the other Detour windows stay behind the app
    /// that was in front (seen on macOS 26.7 with the cooperative `activate()`,
    /// `NSRunningApplication.activate(options: [])` and the deprecated
    /// `activate(ignoringOtherApps:)`, before or after opening the window).
    /// The request is honoured because Detour holds the key focus (the panel)
    /// when Return is pressed in it.
    ///
    /// Not guarded on `NSApp.isActive`: that is already true while the
    /// non-activating panel is key, although the other app keeps the menu bar
    /// and stays frontmost, so the guard skipped the activation and the
    /// window opened behind the other app.
    static func defaultOpenWindow(_ profile: Profile, _ sourceSpace: Space?, _ url: URL, _ typed: Bool) {
        QuickDetourWindowController.open(profile: profile, sourceSpace: sourceSpace, url: url, typed: typed)
        NSApp.activate()
    }

    var palette: CommandPaletteView? { panel?.palette }
    var isShowing: Bool { panel?.isVisible ?? false }

    /// Shows the palette for a Quick Detour on `profile`, suggesting from the
    /// profile's history. `sourceSpace` is the space of the window it was
    /// asked from, which Open in names (TASK-193.3).
    func show(profile: Profile, sourceSpace: Space?) {
        if let panel, panel.isVisible, self.profile === profile {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        close()
        self.profile = profile
        sourceSpaceID = sourceSpace?.id

        let panel = QuickDetourPalettePanel()
        let palette = CommandPaletteView()
        palette.delegate = self
        // No open tabs: switching to one would bring a browser window forward
        // instead of opening a Quick Detour.
        palette.tabStore = nil
        palette.profile = profile
        // The profile's whole history (TASK-209), whichever window asked.
        palette.historySpaceIDs = PaletteTabScope.historySpaceIDs(profile: profile, in: .shared)
        palette.glassTint = QuickDetourPalettePanel.glassTint
        panel.palette = palette
        // Close Tab (⌘W) in the launcher closes it (TASK-348).
        panel.onCloseCommand = { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.close()
        }
        panel.setFrame(QuickDetour.panelFrame(size: panel.frame.size, in: Self.targetScreen().visibleFrame),
                       display: false)
        self.panel = panel
        resignObserver = NotificationCenter.default.addMainObserver(
            forName: NSWindow.didResignKeyNotification, object: panel) { [weak self, weak panel] _ in
            guard let self, let panel, self.panel === panel else { return }
            self.close()
        }
        panel.makeKeyAndOrderFront(nil)
        // After the panel is key, so the field takes first responder.
        palette.show(in: panel.paletteHost)
    }

    /// Closes the panel; nothing opens. Lets go of the profile too: the
    /// launcher is a singleton, and a profile it kept would outlive its
    /// deletion and hold its data store in use (`TabStore.deleteProfile`).
    func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        profile = nil
        sourceSpaceID = nil
        guard let panel else { return }
        self.panel = nil
        panel.palette?.delegate = nil
        panel.onCloseCommand = nil
        panel.palette?.removeFromSuperview()
        panel.orderOut(nil)
        panel.close()
    }

    /// The screen the panel opens on: the key window's while Detour is active,
    /// else the one under the pointer (the hotkey path, TASK-193.2), else the
    /// main screen.
    private static func targetScreen() -> NSScreen {
        if NSApp.isActive, let screen = NSApp.keyWindow?.screen { return screen }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func submit(_ url: URL, typed: Bool) {
        guard let profile else { return close() }
        let sourceSpace = sourceSpaceID.flatMap { TabStore.shared.space(withID: $0) }
        close()
        openWindow(profile, sourceSpace, url, typed)
    }
}

extension QuickDetourLauncher: CommandPaletteDelegate {
    func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String) {
        if let url = AddressInputClassifier.directURL(from: input) {
            submit(url, typed: true)
        } else if let url = profile?.searchEngine.searchURL(for: input) {
            submit(url, typed: false)
        }
    }

    func commandPalette(_ palette: CommandPaletteView, didSubmitSearch query: String) {
        guard let url = profile?.searchEngine.searchURL(for: query) else { return }
        submit(url, typed: false)
    }

    func commandPalette(_ palette: CommandPaletteView, didSubmitSiteSearch url: URL) {
        submit(url, typed: false)
    }

    /// Escape on the empty field, or a click outside the palette.
    func commandPaletteDidDismiss(_ palette: CommandPaletteView) {
        close()
    }
}

/// The panel the launcher's palette sits in: borderless and transparent, so
/// the palette's own glass is all that shows; non-activating, floating, on
/// every Space and over full-screen apps.
final class QuickDetourPalettePanel: NSPanel {
    /// The palette fills this view and centres its glass box in it.
    let paletteHost = NSView()
    weak var palette: CommandPaletteView?

    /// The palette's glass tint in the panel. With no window content behind
    /// it, Liquid Glass shows whatever the screen has there, and over a light
    /// window it read light grey in dark mode (seen 2026-10-25). Resolved per
    /// appearance, so it is dark in dark mode and light in light mode
    /// whatever is behind, as Spotlight's is.
    static let glassTint = NSColor(name: "QuickDetourPanelGlassTint") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.11, alpha: 0.82)
            : NSColor(white: 0.98, alpha: 0.62)
    }

    /// Room for the palette's box with its full list, and its shadow.
    static var contentSize: NSSize {
        let listHeight = CGFloat(PaletteRows.visibleRows) * 36
        return NSSize(width: CommandPaletteView.width + 60, height: 12 + 24 + 8 + 1 + listHeight + 60)
    }

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        title = "\(QuickDetour.displayName)"
        paletteHost.frame = NSRect(origin: .zero, size: Self.contentSize)
        paletteHost.autoresizingMask = [.width, .height]
        contentView = paletteHost
    }

    /// A borderless window does not become key on its own; this one has to,
    /// so typing goes straight to the palette.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Undo (TASK-346)

    /// Edit > Undo and Redo (`browserUndo:`/`browserRedo:`, ⌘Z / ⇧⌘Z) undo
    /// and redo the field's typing here, and never the browser's list
    /// (`FieldUndo`). The panel is in its field's responder chain, so it
    /// answers them itself: with no answer in the panel, AppKit went on to the
    /// main window, a browser window, whose `browserUndo:` ran `TabStore`'s
    /// undo (a closed tab reopened behind the launcher). As Quick Detour and
    /// quarantine windows answer them for their page (TASK-345). The
    /// in-window palette is a browser window's and keeps the browser's undo
    /// there.
    @objc func browserUndo(_ sender: Any?) { FieldUndo.undo(in: self) }

    @objc func browserRedo(_ sender: Any?) { FieldUndo.redo(in: self) }

    /// The undo manager of what has the keys: the field editor while the
    /// palette's field is edited, which registers its typing with this
    /// panel's own manager (the field has no undo manager of its own).
    var fieldUndoManager: UndoManager? { FieldUndo.undoManager(in: self) }

    /// Undo and Redo are titled from the field's undo ("Undo Typing") and
    /// enabled only when it has something; disabled with nothing typed.
    /// Close Tab is enabled (it closes the launcher); every other browser
    /// window command is disabled here (TASK-348).
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let answer = FieldUndo.validate(menuItem, in: self) { return answer }
        if menuItem.action == BrowserCommands.closeTab.action { return true }
        if let action = menuItem.action, Self.windowControllerActions.contains(action) {
            // Back to the registry's title: a browser window retitles some
            // ("Unpin Tab", "Open Peek in New Tab"), which would otherwise
            // show here, disabled, naming a tab the launcher does not have.
            if let command = BrowserCommands.command(for: menuItem), command.contextualTitle != nil {
                menuItem.title = command.title
            }
            return false
        }
        return super.validateMenuItem(menuItem)
    }

    // MARK: - Browser-window commands (TASK-348)

    /// What Close Tab (⌘W) does here: closes the launcher, opening nothing.
    /// Set by the launcher that owns the panel.
    var onCloseCommand: (() -> Void)?

    /// The actions of the registry's window-controller commands. The panel
    /// answers every one of them below, so none falls through to the main
    /// window: the panel has no controller, its delegate answers none and it
    /// never becomes main, so a nil-target action AppKit found nothing for in
    /// the panel's chain went on to the main window's (measured: ⌘W closed a
    /// tab in the browser window behind the launcher, ⇧⌘T reopened one, ⌘D
    /// pinned one, ⌘Y opened History, ⌘T and ⌘L opened its palette).
    /// `QuickDetourLauncherTests` checks that each one stops here, so a
    /// command added to the registry needs a method below.
    static let windowControllerActions: Set<Selector> = Set(BrowserCommands.all.compactMap { command in
        if case .windowController = command.responder { return command.action }
        return nil
    })

    /// ⌘W closes the launcher, as Escape on an empty field does. Chosen by
    /// Claude (TASK-348), not yet confirmed by the user; the alternative was
    /// disabling it like the others.
    /// Kept alive to the end: closing drops the launcher's reference to the
    /// panel while this method runs.
    @objc func closeCurrentTab(_ sender: Any?) { withExtendedLifetime(self) { onCloseCommand?() } }

    // The rest do nothing here, and validate as disabled (a beep for their
    // key equivalent). The field has the keys, so Open Location (⌘L) has
    // nothing to open, and the launcher has no tab, page, space or history
    // of its own. Chosen by Claude (TASK-348), not yet confirmed by the user.
    @objc func newTab(_ sender: Any?) {}
    @objc func focusAddressBar(_ sender: Any?) {}
    @objc func reopenClosedTab(_ sender: Any?) {}
    @objc func togglePinTab(_ sender: Any?) {}
    @objc func splitSelectedTabWith(_ sender: Any?) {}
    @objc func openInDefaultSpace(_ sender: Any?) {}
    @objc func copyCurrentURL(_ sender: Any?) {}
    @objc func showFindBar(_ sender: Any?) {}
    @objc func findNext(_ sender: Any?) {}
    @objc func findPrevious(_ sender: Any?) {}
    @objc func toggleSidebarMode(_ sender: Any?) {}
    @objc func reloadPage(_ sender: Any?) {}
    @objc func zoomActualSize(_ sender: Any?) {}
    @objc func zoomIn(_ sender: Any?) {}
    @objc func zoomOut(_ sender: Any?) {}
    @objc func goBack(_ sender: Any?) {}
    @objc func goForward(_ sender: Any?) {}
    /// NSWindow's own (window tabbing), which the panel has no use for.
    override func selectNextTab(_ sender: Any?) {}
    override func selectPreviousTab(_ sender: Any?) {}
    @objc func showHistory(_ sender: Any?) {}
    @objc func showArchivedTabs(_ sender: Any?) {}
    @objc func clearArchivedTabs(_ sender: Any?) {}
    @objc func nextSpace(_ sender: Any?) {}
    @objc func previousSpace(_ sender: Any?) {}
    @objc func jumpToSpace1(_ sender: Any?) {}
    @objc func jumpToSpace2(_ sender: Any?) {}
    @objc func jumpToSpace3(_ sender: Any?) {}
    @objc func jumpToSpace4(_ sender: Any?) {}
    @objc func jumpToSpace5(_ sender: Any?) {}
    @objc func jumpToSpace6(_ sender: Any?) {}
    @objc func jumpToSpace7(_ sender: Any?) {}
    @objc func jumpToSpace8(_ sender: Any?) {}
    @objc func jumpToSpace9(_ sender: Any?) {}
    @objc func selectSpaceFromMenu(_ sender: Any?) {}
    @objc func moveSelectedTabToSpace(_ sender: Any?) {}
    @objc func openSpacesSettings(_ sender: Any?) {}
    @objc func showWebInspector(_ sender: Any?) {}
}
