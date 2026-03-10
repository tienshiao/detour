import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [BrowserWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        // Initialize database before restoring session
        _ = AppDatabase.shared

        let wc = BrowserWindowController()
        windowControllers.append(wc)
        wc.showWindow(nil)

        let restored = TabStore.shared.restoreSession()

        // Ensure at least one space exists
        TabStore.shared.ensureDefaultSpace()

        // Set the window's active space from the restored session
        if let restored, TabStore.shared.space(withID: restored.spaceID) != nil {
            wc.setActiveSpace(id: restored.spaceID)
            if let tabID = restored.tabID {
                wc.selectTab(id: tabID)
            }
        } else if let firstSpace = TabStore.shared.spaces.first {
            wc.setActiveSpace(id: firstSpace.id)
            if let firstTab = firstSpace.tabs.first {
                wc.selectTab(id: firstTab.id)
            }
        }

        observeWindowClose(wc)
    }

    func applicationWillTerminate(_ notification: Notification) {
        TabStore.shared.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func createNewWindow() {
        let wc = BrowserWindowController()
        windowControllers.append(wc)
        wc.showWindow(nil)
        wc.newTab(nil)
        observeWindowClose(wc)
    }

    private func observeWindowClose(_ wc: BrowserWindowController) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: wc.window,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            self.windowControllers.removeAll { $0.window === notification.object as? NSWindow }
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MyBrowser", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MyBrowser", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MyBrowser", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(BrowserWindowController.newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(BrowserWindowController.closeCurrentTab(_:)), keyEquivalent: "w")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "New Window", action: #selector(createNewWindow), keyEquivalent: "n")
        fileMenuItem.submenu = fileMenu

        // Edit menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find...", action: #selector(BrowserWindowController.showFindBar(_:)), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Find Next", action: #selector(BrowserWindowController.findNext(_:)), keyEquivalent: "g")
        let findPrevItem = editMenu.addItem(withTitle: "Find Previous", action: #selector(BrowserWindowController.findPrevious(_:)), keyEquivalent: "g")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        editMenuItem.submenu = editMenu

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let toggleSidebarItem = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(BrowserWindowController.toggleSidebarMode(_:)), keyEquivalent: "s")
        toggleSidebarItem.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(withTitle: "Reload Page", action: #selector(BrowserWindowController.reloadPage(_:)), keyEquivalent: "r")
        viewMenuItem.submenu = viewMenu

        // Navigate menu
        let navigateMenuItem = NSMenuItem()
        mainMenu.addItem(navigateMenuItem)
        let navigateMenu = NSMenu(title: "Navigate")
        navigateMenu.addItem(withTitle: "Back", action: #selector(BrowserWindowController.goBack(_:)), keyEquivalent: "[")
        navigateMenu.addItem(withTitle: "Forward", action: #selector(BrowserWindowController.goForward(_:)), keyEquivalent: "]")
        navigateMenuItem.submenu = navigateMenu

        // Develop menu
        let developMenuItem = NSMenuItem()
        mainMenu.addItem(developMenuItem)
        let developMenu = NSMenu(title: "Develop")
        let inspectorItem = developMenu.addItem(withTitle: "Web Inspector", action: #selector(BrowserWindowController.showWebInspector(_:)), keyEquivalent: "i")
        inspectorItem.keyEquivalentModifierMask = [.command, .option]
        developMenuItem.submenu = developMenu

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
