import AppKit
import Sparkle
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "app")

class AppDelegate: NSObject, NSApplicationDelegate {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: AppDelegate.startsUpdater, updaterDelegate: nil, userDriverDelegate: nil)
    /// Owns the browser window controllers: nothing else keeps an
    /// `NSWindowController` alive. Ownership only. Whether a window is open is
    /// its controller's `hasClosed` and nothing else (TASK-314). A window
    /// leaves this list when it closes, so a closed controller found here
    /// means the two have drifted apart (asserted in `observeWindowClose`).
    private(set) var windowControllers: [BrowserWindowController] = []
    /// Each registered window's will-close observer, removed when it fires.
    private var windowCloseObservers: [ObjectIdentifier: any NSObjectProtocol] = [:]
    /// Which Get URL events carry the links that launched Detour (TASK-304).
    private var launchLinks = LaunchLinkTracker()
    /// Links from other apps that arrived while launching, opened once the
    /// session is restored, with the sender read when each arrived.
    private var linksAwaitingLaunch: [(urls: [URL], sourceApp: String?)] = []
    /// File > New Quick Detour Window.
    private(set) var quickDetourMenuItem: NSMenuItem?
    /// Applies the user's shortcuts to the menu bar when they change (TASK-327).
    private var shortcutBindingsObserver: NSObjectProtocol?
    private var keyboardLayoutObserver: NSObjectProtocol?

    /// Whether this process is the XCTest host (the test runner injects
    /// `XCTest*` variables into the app it launches).
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
    }

    /// An automation test run (`DETOUR_MCP=1` with an isolated data
    /// directory), whether or not its endpoint started (TASK-228.3).
    static var isAutomationTestRun: Bool {
        AutomationGate.isTestRunRequested(environment: ProcessInfo.processInfo.environment)
    }

    /// Whether another process with Detour's bundle id is running now.
    static var anotherInstanceIsRunning: Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let current = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != current }
    }

    /// Whether Sparkle's updater may run in this process (TASK-41).
    ///
    /// Sparkle keeps its schedule and check results in `SU*` keys of the bundle
    /// id's standard defaults domain — the production app's. The XCTest host and
    /// isolated `DETOUR_DATA_DIR` runs share that bundle id, so an updater
    /// started there would schedule or perform checks on the production app's
    /// behalf and record them in its domain. Only a real run in the default data
    /// directory starts the updater; when it does not, the "Check for Updates…"
    /// item is left out of the menu entirely, so nothing can start a check by
    /// hand either. Both inputs are process-constant, hence the `let`.
    static let startsUpdater: Bool =
        !AppDelegate.isRunningUnitTests && WebKitStorageScope.currentIsDefaultDataDirectory

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Detour's own Get URL handler (TASK-304), installed before launch
        // finishes so it also gets the event that launched Detour, while
        // that event is being handled: its sender names the app the link
        // came from. AppKit's handler queued the launch URLs and called
        // `application(_:open:)` after launch, with no event to read a sender
        // from. Files (Open Documents) still reach `application(_:open:)`.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A test run never reads the user's Arc folder (TASK-228.3): Arc's
        // data is looked for in the run's own data directory instead, where
        // only a fixture is (the endpoint's open_ui shows the offer on demand).
        // First, before anything at launch could look for Arc's data.
        if Self.isAutomationTestRun {
            ArcSidebarReader.dataDirectoryOverride.withLock {
                $0 = detourDataDirectory().appending(path: "Arc", directoryHint: .isDirectory)
            }
        }

        // A SIGTERM to Detour ends its native hosts before the app dies
        // (TASK-243); without it they are left running.
        NativeMessagingHost.installSIGTERMHandler()
        setupMainMenu()
        // The user's shortcuts (TASK-327): a change reaches the menu bar, and
        // with it every window, the palette's shortcut column and the
        // key-equivalent fast path, at once.
        shortcutBindingsObserver = NotificationCenter.default.addMainObserver(
            forName: ShortcutBindingStore.didChangeNotification, object: ShortcutBindingStore.shared) { _ in
            ShortcutBindingStore.shared.apply(to: NSApp.mainMenu)
        }
        // Two saved shortcuts that are one keystroke on this keyboard layout
        // (TASK-343: saved before the recorder refused them, or colliding on
        // a layout chosen since): logged now and on every layout change;
        // Settings > Shortcuts marks them. Both keep their shortcuts.
        ShortcutBindingStore.shared.reportSameKeystrokeConflicts()
        keyboardLayoutObserver = DistributedNotificationCenter.default().addMainObserver(
            forName: KeyboardLayout.selectionDidChangeNotification, object: nil) { _ in
            ShortcutBindingStore.shared.reportSameKeystrokeConflicts()
        }

        // The Quick Detour hotkey (TASK-193.2): the menu item mirrors the
        // shortcut everywhere; `start` registers the system-wide hotkey only
        // where `QuickDetourHotKeyAvailability` allows it (never in the test
        // host; in a Debug build only with DETOUR_GLOBAL_HOTKEY=1).
        let quickDetourHotKey = QuickDetourHotKey.shared
        quickDetourHotKey.menuItem = quickDetourMenuItem
        quickDetourHotKey.start { [weak self] in self?.quickDetourHotKeyPressed() }

        if !Self.startsUpdater {
            // Say so once at launch: a run that silently never checks for
            // updates is otherwise indistinguishable from one that does (TASK-41).
            let reason = Self.isRunningUnitTests
                ? "XCTest host"
                : "data directory \(WebKitStorageScope.currentDataDirectoryName)"
            log.notice("Sparkle updater not started: \(reason, privacy: .public); Check for Updates… is unavailable")
        }

        // Initialize databases before restoring session
        _ = AppDatabase.shared
        _ = HistoryDatabase.shared

        // Remove the on-disk data of profiles deleted in an earlier run whose
        // removal did not finish (TASK-32). This must come before anything that
        // creates a profile's data store or extension controller: the window,
        // the extension manager's window-focus handler and restoreSession. An
        // isolated data directory removes only storage it recorded creating
        // (TASK-36). Not in the XCTest host, as a second defence: its data
        // directory's leftovers are cleaned by the test bundle instead.
        if !Self.isRunningUnitTests {
            TabStore.shared.retryPendingProfileDataRemovals()
        }

        // Extension notifications an earlier launch left in Notification
        // Center map to nothing any more (TASK-248). Not in the XCTest host:
        // this runs before the bundle installs its fake center, and the real
        // one is the developer's Detour's. Not while another Detour process
        // runs either (the production app beside an isolated data directory
        // run, or the reverse): they share the bundle id and so the center,
        // and what this one would take for leftovers may be that process's
        // live notifications.
        if !Self.isRunningUnitTests && !Self.anotherInstanceIsRunning {
            Task { await ExtensionNotificationManager.shared.removeLeftoverNotifications() }
        } else if !Self.isRunningUnitTests {
            log.notice("Not removing leftover extension notifications: another Detour process is running")
        }

        // Prune old history off the launch critical path. expireOldVisits() is
        // already a fire-and-forget async write; defer the call itself so the
        // full-table anti-join is not even scheduled until after first paint.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            HistoryDatabase.shared.expireOldVisits()
            // By now the session is restored, which is what makes a space
            // "no longer existing" rather than "not loaded yet" (TASK-87).
            if !Self.isRunningUnitTests { TabStore.shared.sweepHistoryOfDeletedSpaces() }
        }

        // Initialize content blocker (fetch/compile rule lists)
        ContentBlockerManager.shared.initialize()

        // Initialize extension manager before window creation so toolbar
        // items are available when the toolbar delegate is first queried
        ExtensionManager.shared.initialize()
        // Extension updates: a check once the extensions have loaded if one is
        // due, then on Chrome's cadence while the app runs (TASK-113). Never in
        // the test host, which must not reach the network.
        if !Self.isRunningUnitTests {
            ExtensionUpdater.shared.startPeriodicChecks()
        }

        let wc = BrowserWindowController(incognito: false)
        // Registered and observed together, as every other window is, so the
        // registry can never hold a closed controller (TASK-314).
        registerWindowController(wc)
        wc.showWindow(nil)

        let restored = TabStore.shared.restoreSession()

        // Ensure at least one space exists
        TabStore.shared.ensureDefaultSpace()

        // Start periodic tab archival
        TabStore.shared.startArchiveTimer()

        // Sleep hidden tabs on macOS memory pressure (TASK-407). Not in the test
        // host, whose tests deliver pressure events themselves.
        if !Self.isRunningUnitTests { TabStore.shared.memoryPressureSleeper.start() }

        // Close Quick Detours left unused into the archive (TASK-193.5). Not in
        // the test host, whose tests drive the monitor on their own clock.
        if !Self.isRunningUnitTests { QuickDetourIdleMonitor.shared.start() }

        // Recycle WebKit's GPU process before it runs out of IOSurfaces (TASK-105)
        GPUProcessRecycler.shared.start()

        // Kill GPU processes WebKit abandoned without them exiting (TASK-175)
        GPUProcessOrphanReaper.shared.start()

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

        // Last: the links that launched Detour, now that the session and
        // the routes are loaded (TASK-304).
        launchLinks.launchDidFinish(at: ProcessInfo.processInfo.systemUptime)
        let awaiting = linksAwaitingLaunch
        linksAwaitingLaunch = []
        for links in awaiting {
            openExternalURLs(links.urls, sourceApp: links.sourceApp, launchedDetour: true)
        }

        // The automation endpoint (TASK-228.1): off unless the user turned it
        // on, or a test run asked for it with an isolated data directory.
        AutomationController.shared.startIfEnabled(isRunningUnitTests: Self.isRunningUnitTests)

        // Once the first window has settled: the one-time Arc import offer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.offerArcImportIfNeeded(over: wc)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AutomationController.shared.stop()
        QuickDetourHotKey.shared.stop()
        QuickDetourIdleMonitor.shared.stop()
        // Open Quick Detours go to the archive at quit (TASK-193.1's decision,
        // TASK-193.5); nothing restores them as windows.
        TabStore.shared.archiveOpenQuickDetours()
        // Quitting ends the Private session without closing its windows, so
        // `endPrivateSessionIfUnused` never runs: its extensions'
        // notifications go here, or they stay in Notification Center (TASK-238).
        TabStore.shared.removePrivateProfileNotifications()
        TabStore.shared.undoManager.removeAllActions()
        TabStore.shared.saveNow()
        // A download that ended inside the manager's 1 s save debounce would
        // otherwise be missing after the relaunch (TASK-143).
        DownloadManager.shared.flushPendingSave()
        // Last, as it can wait: exiting ends no native host by itself, nor
        // a torn-down one's pending SIGKILL. Every host still running gets
        // SIGTERM, then SIGKILL if it outlasts the bounded wait (TASK-243).
        NativeMessagingHost.terminateAllSpawnedHosts(within: NativeMessagingHost.quitGrace, refusingNewHosts: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Open windows by `hasClosed`, not the registry's size (TASK-314).
        let windowCount = windowControllers.count(where: { !$0.hasClosed })
        guard windowCount > 0 else {
            // No browser window to ask from, but a Private Quick Detour
            // (TASK-193.1) may still be downloading: its partial files go as a
            // Private window's do at quit.
            DownloadManager.shared.cancelPrivateDownloads(closing: .allWindows)
            return .terminateNow
        }

        // A Private window's downloads are listed nowhere once it is gone, and
        // nothing of them is kept for the next launch: quitting cancels the
        // ones still running, and the confirmation says so (TASK-156).
        let downloads = DownloadManager.shared
        let privateDownloads = downloads.privateDownloadsInFlight(closing: .allWindows).count

        let alert = NSAlert()
        alert.messageText = "Quit Detour?"
        let windows = windowCount == 1
            ? "You have 1 window open."
            : "You have \(windowCount) windows open."
        alert.informativeText = [windows, PrivateDownloadClosePolicy.quitWarning(inFlightCount: privateDownloads)]
            .compactMap { $0 }
            .joined(separator: " ")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        downloads.cancelPrivateDownloads(closing: .allWindows)
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            createNewWindow()
        }
        return true
    }

    @objc func loadUnpackedExtension() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select an unpacked extension directory containing manifest.json"
        panel.prompt = "Load Extension"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                // Parse manifest for display name
                let manifestURL = url.appendingPathComponent("manifest.json")
                let manifest = try ExtensionManifest.parse(at: manifestURL)
                let displayName = WebExtension.resolveI18nName(manifest.name, basePath: url, defaultLocale: manifest.defaultLocale)

                let confirmAlert = NSAlert()
                confirmAlert.messageText = "Install \"\(displayName)\"?"
                // On in the frontmost normal window's profile only (TASK-312).
                let target = ExtensionInstallTarget.profileForFrontWindow()
                let targetName = ExtensionInstallTarget.profileName(target)
                confirmAlert.informativeText = targetName.map {
                    "This extension will be installed and turned on in the \"\($0)\" profile."
                } ?? "This extension will be installed."
                confirmAlert.alertStyle = .warning
                confirmAlert.addButton(withTitle: "Install")
                confirmAlert.addButton(withTitle: "Cancel")

                guard confirmAlert.runModal() == .alertFirstButtonReturn else { return }

                // Record the folder so Develop > Reload can reinstall from it (TASK-113).
                var options = ExtensionInstaller.Options()
                options.source = .unpacked
                options.sourcePath = url
                try ExtensionManager.shared.install(from: url, options: options, turningOnIn: target)
                // Toolbar rebuild is handled by extensionsDidChangeNotification
                let alert = NSAlert()
                alert.messageText = "Extension Installed"
                alert.informativeText = ExtensionInstallTarget.installedMessage(displayName: displayName,
                                                                                profileName: targetName)
                alert.alertStyle = .informational
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Failed to Load Extension"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    @objc func showAboutPanel(_ sender: Any?) {
        BuildInfo.showAboutPanel()
    }

    @objc func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
    }

    /// File › Import from Arc… (TASK-293.3).
    @objc func importFromArc(_ sender: Any?) {
        ArcImportWindowController.shared.present()
    }

    /// The one-time offer to import from Arc (TASK-293.3, TASK-293.5): once,
    /// to anyone whose Mac has Arc's data with something in it, whatever they
    /// answer. Arc's sidebar is read first so the sheet shows their spaces.
    private func offerArcImportIfNeeded(over windowController: BrowserWindowController) {
        // Never at the launch of a test run (TASK-228.3): a capture asks for
        // it with open_ui, from a fixture folder.
        guard !Self.isAutomationTestRun else { return }
        let offer = ArcImportOffer.live
        guard offer.isDue(isTestHost: Self.isRunningUnitTests) else { return }
        Task {
            let snapshot = await Task.detached(priority: .userInitiated) { () -> ArcImportSnapshot? in
                try? ArcSidebarReader.read()
            }.value
            // Unreadable this time: the offer waits for a later launch.
            guard let snapshot, offer.isDue(isTestHost: Self.isRunningUnitTests) else { return }
            guard ArcImportOffer.isWorthOffering(snapshot) else {
                offer.markShown()
                return
            }
            // The launch window, else any open normal window; with none, a later launch.
            let target = [windowController] + windowControllers
            guard let host = target.first(where: { !$0.hasClosed && !$0.isIncognito && $0.window?.isVisible == true }),
                  ArcImportOfferSheetController.present(snapshot, over: host) else { return }
            offer.markShown()
        }
    }

    @objc func showExtensionsSettings() {
        SettingsWindowController.shared.showExtensionsPane()
    }

    @objc func createNewWindow() {
        let wc = BrowserWindowController(incognito: false)
        assignDefaultSpace(to: wc)
        wc.showWindow(nil)
        wc.newTab(nil)
        registerWindowController(wc)
    }

    /// A new window with `url` in a tab; a Private one when `incognito` (a
    /// link routed to Private), which has its own space.
    func createNewWindowWithURL(_ url: URL, incognito: Bool = false) {
        let wc = BrowserWindowController(incognito: incognito)
        assignDefaultSpace(to: wc)
        if let space = wc.activeSpace {
            let tab = TabStore.shared.addTab(in: space, url: url)
            wc.selectTab(id: tab.id)
        }
        wc.showWindow(nil)
        registerWindowController(wc)
    }

    /// A new normal window on `space`, with no tab added — the caller selects
    /// what it opened there (TASK-103: an extension's options page).
    @discardableResult
    func createNewWindow(showing space: Space) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: false)
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        registerWindowController(wc)
        return wc
    }

    @objc func createNewIncognitoWindow() {
        let wc = BrowserWindowController(incognito: true)
        wc.showWindow(nil)
        wc.newTab(nil)
        registerWindowController(wc)
    }

    /// File > New Quick Detour Window (TASK-193.1): the launcher panel, for a
    /// Quick Detour on the profile of the frontmost window — a browser window's active space, the
    /// Private profile for a Private window, a Quick Detour's own — else the
    /// first normal profile (`QuickDetour.profileForNewWindow`).
    @objc func newQuickDetourWindow(_ sender: Any?) {
        // The shortcut pressed while the panel is up closes it, as the global
        // hotkey does (TASK-193.2); choosing the item shows it.
        if NSApp.currentEvent?.type == .keyDown, QuickDetourLauncher.shared.isShowing {
            QuickDetourLauncher.shared.close()
            return
        }
        showQuickDetourLauncher()
    }

    /// The global hotkey (TASK-193.2), pressed in any app, Detour included:
    /// shows the launcher over whatever is in front, without activating
    /// Detour; pressed again while it is up, closes it (as Spotlight's does).
    func quickDetourHotKeyPressed() {
        if QuickDetourLauncher.shared.isShowing {
            QuickDetourLauncher.shared.close()
        } else {
            showQuickDetourLauncher()
        }
    }

    private func showQuickDetourLauncher() {
        // A quarantine names no profile to browse with (TASK-194): the window
        // behind it decides.
        // Never a closed browser window AppKit still lists (TASK-314).
        let frontmost = NSApp.orderedWindows.lazy.compactMap { $0.windowController }.first {
            ($0 as? BrowserWindowController)?.hasClosed == false
                || ($0 as? QuickDetourWindowController)?.isQuarantine == false
        }
        let sourceSpace = (frontmost as? BrowserWindowController)?.activeSpace
        let frontmostProfile = sourceSpace?.profile ?? (frontmost as? QuickDetourWindowController)?.profile
        guard let profile = QuickDetour.profileForNewWindow(frontmostSpaceProfile: frontmostProfile,
                                                            profiles: TabStore.shared.profiles) else { return }
        QuickDetourLauncher.shared.show(profile: profile, sourceSpace: sourceSpace)
    }

    private var keyBrowserWindowController: BrowserWindowController? {
        NSApp.keyWindow?.windowController as? BrowserWindowController
    }

    /// Sets the active space on a new non-incognito window using the best available default.
    func assignDefaultSpace(to wc: BrowserWindowController) {
        guard !wc.isIncognito else { return }
        if let currentWC = keyBrowserWindowController,
           !currentWC.isIncognito,
           let spaceID = currentWC.activeSpaceID,
           TabStore.shared.space(withID: spaceID) != nil {
            wc.setActiveSpace(id: spaceID, selectTab: false)
        } else if let lastID = TabStore.shared.lastActiveSpaceID,
                  TabStore.shared.space(withID: lastID) != nil {
            wc.setActiveSpace(id: lastID, selectTab: false)
        } else if let firstSpace = TabStore.shared.spaces.first(where: { !$0.isIncognito }) {
            wc.setActiveSpace(id: firstSpace.id, selectTab: false)
        }
    }

    /// Links opened from another app: Get URL Apple Events, every one of
    /// them since Detour handles the event itself (TASK-304), including the
    /// one that launches Detour. Link Routes pick where each goes
    /// (TASK-191.2); a route may name the sending app, read from the event:
    /// LaunchServices sends it from the opening app's process, so its PID
    /// names the app; a shell's `open` has no bundle ID, so no sender.
    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        let senderPID = linkSenderPID(of: event)
        // Read now: the sender may exit before a launch link is opened.
        let sender = Self.bundleID(ofLinkSender: senderPID)
        let urls = linkURLs(in: event)
        let launching = launchLinks.isLaunching
        let launchedDetour = launchLinks.isLaunchLink(senderPID: senderPID,
                                                      now: ProcessInfo.processInfo.systemUptime)
        if launching {
            linksAwaitingLaunch.append((urls, sender))
        } else {
            openExternalURLs(urls, sourceApp: sender, launchedDetour: launchedDetour)
        }
    }

    /// Documents opened from Finder or the Dock (Open Documents), and any
    /// URLs AppKit still hands over this way. Get URL events go to
    /// `handleGetURLEvent` instead. The sender is read from the event being
    /// handled; only web URLs are opened (a file URL is ignored, as before).
    func application(_ application: NSApplication, open urls: [URL]) {
        let sender = Self.bundleID(ofLinkSender: linkSenderPID(of: NSAppleEventManager.shared().currentAppleEvent))
        openExternalURLs(urls, sourceApp: sender)
    }

    /// The bundle ID of the running app with `senderPID`, by `linkSenderBundleID`.
    private static func bundleID(ofLinkSender senderPID: pid_t?) -> String? {
        linkSenderBundleID(senderPID: senderPID, ownPID: ProcessInfo.processInfo.processIdentifier,
                           bundleIDForPID: { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier })
    }

    /// Opens web links from another app where the routes send them, each URL
    /// on its own. `sourceApp` is the sender's bundle ID, nil when unknown;
    /// `launchedDetour` marks the links that launched Detour, which fail
    /// closed to Quarantine without a known sender wherever a From app route
    /// to Quarantine cannot be ruled out (TASK-304). The decisions
    /// are the pure `resolveExternalLinkRoute` and `linkPlacement`.
    func openExternalURLs(_ urls: [URL], sourceApp: String?, launchedDetour: Bool = false) {
        let store = TabStore.shared
        for url in urls {
            // Case-insensitive: LaunchServices hands over "HTTPS://…" as typed.
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            let decision = resolveExternalLinkRoute(url: url, sourceApp: sourceApp, launchedDetour: launchedDetour,
                                                    routes: store.linkRoutes.routes,
                                                    defaultTarget: store.linkRoutes.defaultTarget,
                                                    context: store.linkRouteContext)
            log.info("External link from \(sourceApp ?? "no known sender", privacy: .public)\(launchedDetour ? " (launched Detour)" : "", privacy: .public): \(String(describing: decision), privacy: .public)")
            openLink(url, routedTo: decision)
        }
    }

    /// Opens `url` where `decision` sends it, by the pure `linkPlacement`: a
    /// link from another app (TASK-191.2), and a typed URL or clicked link a
    /// route moves out of its window's space (TASK-191.4), which never get here
    /// with `.stay`. `typed` marks the visit as typed in history, as a URL
    /// submitted in the palette is when it opens here. `sourceSpace` is the
    /// space a routed click came from, which a quarantine's Open in names.
    /// `sourceWindow` is the window a routed click came from, which comes to
    /// the front again if the link turns out to be a download (TASK-205).
    func openLink(_ url: URL, routedTo decision: LinkRouteDecision, typed: Bool = false, from sourceSpace: Space? = nil,
                  sourceWindow: BrowserWindowController? = nil) {
        // Not a tab in a space, so not the placement's windows (TASK-193.5).
        // The resolver sends only links from other apps here.
        if decision == .quickDetour {
            openInQuickDetour(url, typed: typed)
            return
        }
        // Nor a quarantine (TASK-194): links from other apps and routed
        // clicks, never typed URLs (the resolver's rule).
        if decision == .quarantine {
            openInQuarantine(url, from: sourceSpace)
            return
        }
        let spacesBefore = Dictionary(uniqueKeysWithValues: browserWindowsByRecency.map {
            (ObjectIdentifier($0), $0.activeSpaceID)
        })
        var placedTab: BrowserTab?
        let placed = placeTab(routedTo: decision) { space in
            let tab = TabStore.shared.addTab(in: space)
            tab.load(url, typed: typed)
            placedTab = tab
            return tab
        }
        // What the placement changed, in case the link is a download: the
        // response comes later, so recording it now is in time.
        if let wc = placed, let tab = placedTab, let routedSpaceID = wc.activeSpaceID {
            let id = ObjectIdentifier(wc)
            let previousSpaceID = spacesBefore[id] ?? nil
            tab.routedOpen = RoutedOpenRecord(
                open: DownloadOpenedTabPolicy.RoutedOpen(
                    sourceWindow: sourceWindow.map(ObjectIdentifier.init), placedWindow: id,
                    placedWindowWasCreated: !spacesBefore.keys.contains(id), placedWindowIsPrivate: wc.isIncognito,
                    placedWindowPreviousSpaceID: previousSpaceID == routedSpaceID ? nil : previousSpaceID,
                    routedSpaceID: routedSpaceID),
                sourceWindow: sourceWindow, placedWindow: wc)
        }
        // Never the most recent (normal) space for a link routed to Private.
        if placed == nil, decision != .privateWindow { openInMostRecentSpace(url) }
    }

    /// Puts the windows back after a routed tab closed because its link was a
    /// download (TASK-205, `DownloadOpenedTabPolicy.restoration`).
    func restoreWindows(after open: DownloadOpenedTabPolicy.RoutedOpen<ObjectIdentifier>) {
        let windows = browserWindowsByRecency
        func window(_ id: ObjectIdentifier) -> BrowserWindowController? {
            windows.first { ObjectIdentifier($0) == id }
        }
        let now = DownloadOpenedTabPolicy.Windows(
            open: Set(windows.map(ObjectIdentifier.init)),
            // The key browser window, else Detour's front one (the order
            // starts at the key window): the user may have gone to another app
            // or to Settings, which leaves the browser windows as the placement
            // left them.
            key: windows.first.map(ObjectIdentifier.init),
            activeSpaceID: Dictionary(uniqueKeysWithValues: windows.compactMap { wc in
                wc.activeSpaceID.map { (ObjectIdentifier(wc), $0) }
            }))
        for step in DownloadOpenedTabPolicy.restoration(of: open, windows: now) {
            switch step {
            case .closeWindow(let id):
                window(id)?.window?.close()
            case .switchSpace(let id, let spaceID):
                window(id)?.setActiveSpace(id: spaceID)
            case .bringToFront(let id):
                window(id)?.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Puts a tab where `decision` sends it, by the pure `linkPlacement`, and
    /// returns the window it is selected in, now in front: a link from
    /// another app or a routed link (`openLink`), and Quick Detour's Open in
    /// (TASK-193.3), whose `makeTab` hands over the Quick Detour's own page
    /// instead of opening a URL. `makeTab` gets the receiving space once its
    /// window shows it — switched, or opened for it — so a handed-over tab is
    /// listed by a window the moment it arrives.
    ///
    /// `didSelect` runs once the window has selected the tab, before the
    /// window tells the extension contexts it is active
    /// (`holdingExtensionActivation`): where a handed-over tab's move is
    /// announced.
    ///
    /// Nil when nothing was placed: Most Recent Space (the caller's own
    /// fallback), a window or space gone since the snapshot, or `makeTab`
    /// declining. A Private placement whose window has gone opens a new
    /// Private window instead, as a link always did.
    @discardableResult
    func placeTab(routedTo decision: LinkRouteDecision, makeTab: (Space) -> BrowserTab?,
                  didSelect: ((BrowserWindowController, BrowserTab) -> Void)? = nil) -> BrowserWindowController? {
        // Taken per placement: an earlier one may have opened or switched a window.
        let windows = browserWindowsByRecency
        let placement = linkPlacement(for: decision, windows: windows.map {
            LinkPlacementWindow(id: ObjectIdentifier($0), activeSpaceID: $0.activeSpaceID, isPrivate: $0.isIncognito)
        })
        return place(placement, windows: windows, makeTab: makeTab, didSelect: didSelect)
    }

    /// Browser windows, the most recently active first: front to back, then
    /// any registered window not in the window list (minimized, or the app
    /// hidden) last.
    ///
    /// Open windows only, by `hasClosed`: the registry adds windows AppKit does
    /// not list, never a closed one (TASK-314). During a close the two can
    /// briefly disagree, so this filters rather than asserts.
    private var browserWindowsByRecency: [BrowserWindowController] {
        var ordered = NSApp.browserWindowControllersFrontToBack
        for wc in windowControllers where !wc.hasClosed && !ordered.contains(where: { $0 === wc }) {
            ordered.append(wc)
        }
        return ordered
    }

    private func place(_ placement: LinkPlacement<ObjectIdentifier>, windows: [BrowserWindowController],
                       makeTab: (Space) -> BrowserTab?,
                       didSelect: ((BrowserWindowController, BrowserTab) -> Void)?) -> BrowserWindowController? {
        let store = TabStore.shared
        func window(_ id: ObjectIdentifier) -> BrowserWindowController? {
            windows.first { ObjectIdentifier($0) == id }
        }
        switch placement {
        case .openInWindow(let id):
            guard let wc = window(id), let space = wc.activeSpace else { return nil }
            return present(in: space, of: wc, makeTab: makeTab, didSelect: didSelect)
        case .switchWindow(let id, let spaceID):
            guard let wc = window(id), let space = store.space(withID: spaceID) else { return nil }
            wc.setActiveSpace(id: spaceID, selectTab: false)
            return present(in: space, of: wc, makeTab: makeTab, didSelect: didSelect)
        case .openInNewWindow(let spaceID):
            guard let space = store.space(withID: spaceID) else { return nil }
            return present(in: space, of: createNewWindow(showing: space), makeTab: makeTab, didSelect: didSelect)
        case .openInPrivateWindow(let id):
            guard let wc = window(id), let space = wc.activeSpace else {
                return placeInNewPrivateWindow(makeTab, didSelect: didSelect)
            }
            return present(in: space, of: wc, makeTab: makeTab, didSelect: didSelect)
        case .openInNewPrivateWindow:
            return placeInNewPrivateWindow(makeTab, didSelect: didSelect)
        case .mostRecentSpace:
            return nil
        case .openInQuickDetour, .openInQuarantine:
            // Not a tab in a space: `openLink` opens the window itself.
            return nil
        }
    }

    /// A placed tab: made in `space` of `wc`, selected, and the window in
    /// front. Not a background tab, so a collapsed sidebar does not say one
    /// opened.
    private func present(in space: Space, of wc: BrowserWindowController, makeTab: (Space) -> BrowserTab?,
                         didSelect: ((BrowserWindowController, BrowserTab) -> Void)?) -> BrowserWindowController? {
        guard let tab = wc.withoutBackgroundTabToast({ makeTab(space) }) else { return nil }
        select(tab, in: wc, didSelect: didSelect)
        wc.window?.makeKeyAndOrderFront(nil)
        return wc
    }

    private func select(_ tab: BrowserTab, in wc: BrowserWindowController,
                        didSelect: ((BrowserWindowController, BrowserTab) -> Void)?) {
        guard let didSelect else { return wc.selectTab(id: tab.id) }
        wc.holdingExtensionActivation {
            wc.selectTab(id: tab.id)
            didSelect(wc, tab)
        }
    }

    /// A new Private window holding only the placed tab — no empty tab of its
    /// own, as New Private Window would add. When `makeTab` declines, the
    /// window is never shown and its space goes again.
    private func placeInNewPrivateWindow(_ makeTab: (Space) -> BrowserTab?,
                                         didSelect: ((BrowserWindowController, BrowserTab) -> Void)?)
        -> BrowserWindowController? {
        let wc = BrowserWindowController(incognito: true)
        guard let space = wc.activeSpace, let tab = wc.withoutBackgroundTabToast({ makeTab(space) }) else {
            if let spaceID = wc.activeSpaceID { TabStore.shared.removeIncognitoSpace(id: spaceID) }
            return nil
        }
        select(tab, in: wc, didSelect: didSelect)
        wc.showWindow(nil)
        registerWindowController(wc)
        wc.window?.makeKeyAndOrderFront(nil)
        return wc
    }

    /// A link that Link Routes send to Quick Detour (TASK-193.5): a new
    /// Quick Detour window on the frontmost Detour window's profile — never
    /// Private (`QuickDetour.profileForRoutedLink`) — whose Open in names the
    /// most recent normal window's space when it is that profile's. In front
    /// of Detour's windows, as a placed tab's window is.
    private func openInQuickDetour(_ url: URL, typed: Bool) {
        let store = TabStore.shared
        var windowProfiles: [Profile] = NSApp.orderedWindows.compactMap { window in
            switch window.windowController {
            // Never a closed one AppKit still lists (TASK-314).
            case let browser as BrowserWindowController: return browser.hasClosed ? nil : browser.activeSpace?.profile
            case let quick as QuickDetourWindowController: return quick.isQuarantine ? nil : quick.profile
            default: return nil
            }
        }
        // Windows not in the window list (minimized, the app hidden) last.
        windowProfiles += browserWindowsByRecency.compactMap { $0.activeSpace?.profile }
        guard let profile = QuickDetour.profileForRoutedLink(windowProfiles: windowProfiles,
                                                             profiles: store.profiles) else { return }
        let sourceSpace = browserWindowsByRecency.lazy
            .compactMap { $0.isIncognito ? nil : $0.activeSpace }
            .first { $0.profileID == profile.id }
        log.info("Link routed to Quick Detour on profile \(profile.id.uuidString, privacy: .public)")
        QuickDetourWindowController.open(profile: profile, sourceSpace: sourceSpace, url: url, typed: typed)
    }

    /// A link that Link Routes send to Quarantine (TASK-194): a new quarantine
    /// window on the Private profile with a store of its own, in front of
    /// Detour's windows. Its Open in names the space the link was clicked in,
    /// else the most recent normal window's space.
    private func openInQuarantine(_ url: URL, from clickedIn: Space?) {
        let store = TabStore.shared
        let sourceSpace = clickedIn ?? browserWindowsByRecency.lazy.compactMap { $0.isIncognito ? nil : $0.activeSpace }.first
        log.info("Link routed to Quarantine")
        QuickDetourWindowController.openQuarantine(url: url, privateProfile: store.ensureIncognitoProfile(),
                                                   sourceSpace: sourceSpace)
    }

    /// What a link from another app did before routes, kept exactly (the Most
    /// Recent Space target, TASK-191.2): a tab in the key browser window's
    /// active space, else a new window. With Detour in the background there is
    /// no key window, so that is a new window (unchanged from before routes).
    private func openInMostRecentSpace(_ url: URL) {
        if let wc = keyBrowserWindowController,
           let space = wc.activeSpace {
            let tab = TabStore.shared.addTab(in: space, url: url)
            wc.selectTab(id: tab.id)
        } else {
            createNewWindowWithURL(url)
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Window", action: #selector(createNewWindow as () -> Void), keyEquivalent: "")
        menu.addItem(withTitle: "New Private Window", action: #selector(createNewIncognitoWindow), keyEquivalent: "")
        addQuickDetourDockMenuItem(to: menu)
        return menu
    }

    /// Registers a window controller for lifecycle management and cleanup on close.
    func registerWindowController(_ wc: BrowserWindowController) {
        windowControllers.append(wc)
        observeWindowClose(wc)
    }

    private func observeWindowClose(_ wc: BrowserWindowController) {
        guard let window = wc.window else { return }
        windowCloseObservers[ObjectIdentifier(window)] = NotificationCenter.default.addMainObserver(
            forName: NSWindow.willCloseNotification,
            object: window
        ) { [weak self] notification in
            guard let self else { return }
            // One close per window: the observer goes with it (TASK-315).
            if let window = notification.object as? NSWindow,
               let token = self.windowCloseObservers.removeValue(forKey: ObjectIdentifier(window)) {
                NotificationCenter.default.removeObserver(token)
            }
            self.windowControllers.removeAll { $0.window === notification.object as? NSWindow }
            // The closing window has just left. Any other registered window
            // must be open: a closed one left behind means ownership and
            // `hasClosed` drifted apart (TASK-314). Checked here, not where
            // windows are listed: between a window's own windowWillClose and
            // this removal, the two legitimately disagree.
            assert(self.windowControllers.allSatisfy { !$0.hasClosed },
                   "A closed window is still registered: the registry and hasClosed disagree (TASK-314)")
        }
    }

    /// Adds `command`'s menu item to `menu` (TASK-320): the item is a view
    /// of the registry's command, with the target its responder calls for.
    @discardableResult
    private func add(_ command: BrowserCommand, to menu: NSMenu) -> NSMenuItem {
        let item = command.makeMenuItem()
        switch command.responder {
        case .appDelegate(explicitTarget: true): item.target = self
        case .updater: item.target = updaterController
        case .appDelegate(explicitTarget: false), .windowController, .appKit: break
        }
        menu.addItem(item)
        return item
    }

    /// The app's name, as the menu bar shows it on the application menu.
    static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Detour"

    /// The menu bar's item for `menu`, titled as the menu (TASK-334). The bar
    /// shows the submenu's title either way, but AppKit matches a menu-path
    /// App Shortcut ("File->Close Tab" in System Settings) against the parent
    /// items' titles, and an untitled `NSMenuItem()` is titled "NSMenuItem".
    /// Titled before the submenu is attached: the entries for its items apply
    /// on attaching (measured, docs/harness/task327 spike 3).
    static func menuBarItem(for menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// The menu bar, every item from the command registry (`BrowserCommands`,
    /// TASK-320): its title, key equivalent, action and target. Enablement is
    /// the registry's rule, which the window controllers' `validateMenuItem`
    /// answers. The layout (order, separators, which menus have a delegate)
    /// stays here.
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let commands = BrowserCommands.self

        // App menu
        let appMenu = NSMenu(title: Self.appName)
        add(commands.about, to: appMenu)
        // Not added at all when the updater did not start (TASK-41), so nothing
        // can reach it — and no separator is left standing where it would have been.
        if Self.startsUpdater {
            appMenu.addItem(.separator())
            add(commands.checkForUpdates, to: appMenu)
        }
        appMenu.addItem(.separator())
        add(commands.settings, to: appMenu)
        appMenu.addItem(.separator())
        add(commands.hide, to: appMenu)
        add(commands.hideOthers, to: appMenu)
        add(commands.showAll, to: appMenu)
        appMenu.addItem(.separator())
        add(commands.quit, to: appMenu)
        mainMenu.addItem(Self.menuBarItem(for: appMenu))

        // File menu
        let fileMenu = NSMenu(title: "File")
        add(commands.newTab, to: fileMenu)
        add(commands.openLocation, to: fileMenu)
        add(commands.closeTab, to: fileMenu)
        add(commands.reopenClosedTab, to: fileMenu)
        add(commands.togglePin, to: fileMenu)
        fileMenu.addItem(.separator())
        add(commands.newWindow, to: fileMenu)
        add(commands.newPrivateWindow, to: fileMenu)
        // Opt-Cmd-N by default (TASK-193.1), or the shortcut set for the
        // system-wide hotkey (TASK-193.2). The File menu is not
        // delegate-driven, so AppKit matches it natively.
        // Its key equivalent follows the hotkey's setting (QuickDetourHotKey).
        quickDetourMenuItem = add(commands.newQuickDetourWindow, to: fileMenu)
        // Cmd+O (TASK-193.3): enabled only while a Quick Detour is key, whose
        // controller answers it and names its target in the title, or a Peek
        // is up in a browser window (TASK-307).
        add(commands.openInSpace, to: fileMenu)
        fileMenu.addItem(.separator())
        add(commands.importFromArc, to: fileMenu)
        mainMenu.addItem(Self.menuBarItem(for: fileMenu))

        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        add(commands.undo, to: editMenu)
        add(commands.redo, to: editMenu)
        editMenu.addItem(.separator())
        add(commands.cut, to: editMenu)
        add(commands.copy, to: editMenu)
        add(commands.copyURL, to: editMenu)
        add(commands.paste, to: editMenu)
        add(commands.selectAll, to: editMenu)
        editMenu.addItem(.separator())
        add(commands.find, to: editMenu)
        add(commands.findNext, to: editMenu)
        add(commands.findPrevious, to: editMenu)
        mainMenu.addItem(Self.menuBarItem(for: editMenu))

        // View menu
        let viewMenu = NSMenu(title: "View")
        add(commands.toggleSidebar, to: viewMenu)
        add(commands.reload, to: viewMenu)
        viewMenu.addItem(.separator())
        add(commands.actualSize, to: viewMenu)
        add(commands.zoomIn, to: viewMenu)
        add(commands.zoomOut, to: viewMenu)
        mainMenu.addItem(Self.menuBarItem(for: viewMenu))

        // Navigate menu
        let navigateMenu = NSMenu(title: "Navigate")
        add(commands.back, to: navigateMenu)
        add(commands.forward, to: navigateMenu)
        navigateMenu.addItem(.separator())
        add(commands.previousTab, to: navigateMenu)
        add(commands.nextTab, to: navigateMenu)
        navigateMenu.addItem(.separator())
        // Safari's History menu, in the menu that already holds Back and
        // Forward rather than a second one beside it (TASK-86). Cmd+Y is free:
        // the Navigate menu is not delegate-driven, so AppKit matches it
        // natively and `MenuKeyEquivalentMatcher` never sees it.
        add(commands.showHistory, to: navigateMenu)
        // The sidebar's Archived Tabs page (TASK-119), also reached by swiping
        // right past the first space.
        add(commands.showArchivedTabs, to: navigateMenu)
        add(commands.clearArchivedTabs, to: navigateMenu)
        mainMenu.addItem(Self.menuBarItem(for: navigateMenu))

        // Spaces menu
        let spacesMenu = NSMenu(title: "Spaces")
        spacesMenu.delegate = self
        add(commands.nextSpace, to: spacesMenu)
        add(commands.previousSpace, to: spacesMenu)
        spacesMenu.addItem(.separator())
        // The first nine spaces' items (TASK-295), static so their shortcuts
        // work before the menu is first opened. `updateSpacesMenu` titles
        // them and hides positions with no space; a hidden one keeps its key
        // equivalent (AppKit fires it, measured) so the press is swallowed
        // rather than falling through to the page.
        for command in commands.jumpToSpace {
            add(command, to: spacesMenu).allowsKeyEquivalentWhenHidden = true
        }
        add(commands.manageSpaces, to: spacesMenu)
        mainMenu.addItem(Self.menuBarItem(for: spacesMenu))

        // Extensions menu
        let extensionsMenu = NSMenu(title: "Extensions")
        extensionsMenu.delegate = self
        add(commands.addExtensions, to: extensionsMenu)
        add(commands.manageExtensions, to: extensionsMenu)
        add(commands.checkForExtensionUpdates, to: extensionsMenu)
        mainMenu.addItem(Self.menuBarItem(for: extensionsMenu))

        // Develop menu. Deliberately not delegate-driven: its dynamic items
        // depend only on the global extension list, so they are rebuilt from
        // `extensionsDidChangeNotification` instead of on open. That keeps the
        // one letter shortcut (Cmd+Option+I) out of `menuHasKeyEquivalent`'s
        // hand-rolled matching — AppKit matches it natively, with its own
        // keyboard-layout handling and validation (TASK-56 review).
        let developMenu = NSMenu(title: "Develop")
        add(commands.webInspector, to: developMenu)
        developMenu.addItem(.separator())
        add(commands.loadUnpackedExtension, to: developMenu)
        mainMenu.addItem(Self.menuBarItem(for: developMenu))
        self.developMenu = developMenu
        updateDevelopMenu(developMenu)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(extensionsDidChange),
            name: ExtensionManager.extensionsDidChangeNotification,
            object: nil
        )

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        add(commands.minimize, to: windowMenu)
        add(commands.zoomWindow, to: windowMenu)
        mainMenu.addItem(Self.menuBarItem(for: windowMenu))
        NSApp.windowsMenu = windowMenu

        // Help menu, last (TASK-292.10): registered, so macOS adds its search field.
        let helpMenuItem = makeHelpMenuItem(adding: { self.add($0, to: $1) })
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenuItem.submenu

        // The user's shortcuts over the registry's (TASK-327).
        ShortcutBindingStore.shared.apply(to: mainMenu)
        NSApp.mainMenu = mainMenu
    }

    @objc func openChromeWebStore() {
        let url = URL(string: "https://chromewebstore.google.com")!
        if let wc = keyBrowserWindowController,
           let space = wc.activeSpace {
            let tab = TabStore.shared.addTab(in: space, url: url)
            wc.selectTab(id: tab.id)
        } else {
            createNewWindowWithURL(url)
        }
    }

    @objc func extensionMenuClicked(_ sender: NSMenuItem) {
        guard let extID = sender.representedObject as? String,
              ExtensionManager.shared.context(for: extID) != nil else { return }

        guard let wc = keyBrowserWindowController else { return }
        let addressBar = wc.tabSidebar.fauxAddressBar
        let popover = ExtensionPopoverController(extensionID: extID)
        popover.show(relativeTo: addressBar.bounds, of: addressBar, preferredEdge: .minY)
        // Retain until closed
        objc_setAssociatedObject(wc, "extensionMenuPopover", popover, .OBJC_ASSOCIATION_RETAIN)
    }

    /// "Options…" in an extension's Extensions-menu submenu (TASK-103): opens
    /// the options page in the key window's profile — the profile the menu was
    /// built for.
    @MainActor @objc func extensionOptionsMenuClicked(_ sender: NSMenuItem) {
        guard let extID = sender.representedObject as? String,
              let profile = keyBrowserWindowController?.activeSpace?.profile else { return }
        ExtensionManager.shared.openOptionsPage(for: extID, in: profile)
    }

    // MARK: - Extension Inspector

    /// Tag used to identify dynamically-added space menu items.
    private static let spacesMenuTag = 7000

    /// Tag used to identify dynamically-added extension menu items.
    private static let extensionMenuTag = 8000

    /// Tag used to identify dynamically-added extension inspector menu items.
    private static let extensionInspectorTag = 9000

    /// How many static items end the Extensions menu (the dynamic per-extension
    /// items are inserted above them).
    private static let extensionsMenuStaticItemCount = 3

    /// The Develop menu, rebuilt on `extensionsDidChangeNotification` rather
    /// than by an `NSMenuDelegate` (see `setupMainMenu`).
    private var developMenu: NSMenu?

    /// Every path that changes the extension list or an extension's enabled
    /// flag posts `extensionsDidChangeNotification` (load, install, uninstall,
    /// global and per-profile enable), so the Develop menu is current whenever
    /// it is opened without being rebuilt on open.
    @objc private func extensionsDidChange() {
        guard let developMenu else { return }
        if Thread.isMainThread {
            updateDevelopMenu(developMenu)
        } else {
            DispatchQueue.main.async { [weak self] in self?.updateDevelopMenu(developMenu) }
        }
    }

    /// Hidden windows that host background webViews so the inspector can attach.
    private var inspectorWindows: [String: NSWindow] = [:]

    @objc func inspectExtensionOffscreen(_ sender: NSMenuItem) {
        guard let extID = sender.representedObject as? String else { return }

        let host = TabStore.shared.profiles.lazy
            .compactMap { $0.polyfillHandler?.offscreenHosts[extID] }
            .first
        guard let host,
              let webView = host.webView else {
            let alert = NSAlert()
            alert.messageText = "No Offscreen Document"
            alert.informativeText = "This extension doesn't have an active offscreen document. It will be created when the extension requests one."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }

        // Host the offscreen webView in a visible window so the inspector can attach
        let window: NSWindow
        if let existing = inspectorWindows[extID] {
            window = existing
        } else {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
            let name = ExtensionManager.shared.displayName(for: extID)
            window.title = "\(name) — Offscreen Document"
            inspectorWindows[extID] = window
        }
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)

        // Open the web inspector
        if let inspector = webView.value(forKey: "_inspector") as? NSObject {
            inspector.perform(Selector(("show")))
        }
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.title {
        case "Spaces":
            updateSpacesMenu(menu)
        case "Extensions":
            updateExtensionsMenu(menu)
        default:
            break
        }
    }

    /// Answers AppKit's key-equivalent query, so a Cmd+key press does not
    /// rebuild the Spaces and Extensions menus (TASK-56).
    ///
    /// A delegate that does not implement this method gets `menuNeedsUpdate`
    /// on every key-equivalent dispatch — re-enumerating spaces, re-querying
    /// each profile's enabled extensions and redrawing their icons on every
    /// keystroke, and re-exposing any menu item whose enable decision touches
    /// WebKit state (TASK-55). Implementing it takes the rebuild off the
    /// keystroke path; the rebuild runs when AppKit actually needs the menu's
    /// contents (opening it, accessibility, menu search).
    ///
    /// What the two answers mean, verified against AppKit rather than assumed
    /// (TASK-56 review, macOS 26): `false` is *not* a veto. AppKit goes on to
    /// scan the items the menu already holds — with its own keyboard-layout
    /// handling, validation and submenu recursion — just without rebuilding
    /// first. So a `false` for a shortcut this matcher does not model costs
    /// nothing on that path, and only the static items that exist between
    /// opens can be matched either way (the dynamic items carry no key
    /// equivalent; `MenuKeyEquivalentMatcherTests` asserts it on the real
    /// menus). Whether older AppKit trusts `false` outright is not verified,
    /// which is why the matcher stays as the belt to that braces: every
    /// built-in shortcut left in these menus is on a static item: the arrow
    /// keys of Next/Previous Space, which it matches exactly, and the nine
    /// position items' ⌃1–⌃9 (TASK-295), digits it matches on a layout that
    /// types them unshifted (on one that does not, such as French AZERTY, it
    /// misses and AppKit's own matching decides; not measured). Each position
    /// item has its own action, because a `true` here has AppKit send the
    /// action with the menu, not the item, as sender (measured, TASK-295).
    /// A user's binding (TASK-327) on one of their
    /// static items (Manage Spaces…, Add Extensions…) can be a letter: the
    /// matcher reads the live items, so it answers that too, and a press it
    /// does not model (a layout-dependent character) is a miss AppKit then
    /// matches itself.
    ///
    /// `true`, by contrast, *is* trusted: AppKit performs the returned action
    /// on the returned target with no validation of its own. So this path must
    /// validate the way AppKit would have (`CommandDispatch.isEnabled`, AppKit's
    /// tiered decision) — `validateMenuItem` is what keeps Next/Previous Space
    /// inert when no browser window is key — and, when in doubt, answer
    /// `false` and let AppKit decide.
    func menuHasKeyEquivalent(_ menu: NSMenu,
                              for event: NSEvent,
                              target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        guard let item = MenuKeyEquivalentMatcher.item(matching: event, in: menu.items),
              let itemAction = item.action else { return false }

        // A nil item target means "resolve against the responder chain", which
        // is how the window-controller shortcuts find the key window.
        guard let resolved = NSApp.target(forAction: itemAction, to: item.target, from: item) else {
            return false
        }
        guard CommandDispatch.isEnabled(item, autoenables: menu.autoenablesItems, target: resolved) else { return false }

        target.pointee = resolved as AnyObject
        action.pointee = itemAction
        return true
    }

    private func updateSpacesMenu(_ menu: NSMenu) {
        // Remove previous dynamic space items
        menu.items
            .filter { $0.tag == AppDelegate.spacesMenuTag }
            .forEach { menu.removeItem($0) }

        let spaces = TabStore.shared.nonIncognitoSpaces
        let activeID = keyBrowserWindowController?.activeSpaceID

        // The first nine spaces are the static position items (TASK-295):
        // titled with the space they open now, hidden where there is none.
        for (index, command) in BrowserCommands.jumpToSpace.enumerated() {
            guard let item = menu.items.first(where: { $0.identifier?.rawValue == command.id.rawValue }) else { continue }
            let space = SpaceJump.target(ofPosition: index + 1, in: spaces)
            let title = space.map(Self.spacesMenuTitle) ?? command.title
            // Retitled only on a change: AppKit re-applies App Shortcuts on
            // every retitle (TASK-327).
            if item.title != title { item.title = title }
            item.state = space.map { $0.id == activeID } == true ? .on : .off
            item.isHidden = space == nil
        }

        guard !spaces.isEmpty else { return }

        // Static layout is: [Next, Previous, separator, the nine position
        // items, "Manage Spaces…"]. Insert the items of the spaces after the
        // ninth (the parameterised `space.switch` command, no shortcut) and a
        // trailing separator before "Manage Spaces…".
        let manageIndex = menu.items.firstIndex(where: { $0.action == BrowserCommands.manageSpaces.action }) ?? menu.items.count
        var insertAt = manageIndex

        for space in SpaceJump.unnumbered(spaces) {
            // The parameterised `space.switch` command, one item per space.
            let item = NSMenuItem(title: Self.spacesMenuTitle(space), action: BrowserCommands.switchToSpace.action, keyEquivalent: "")
            item.representedObject = space.id
            item.tag = AppDelegate.spacesMenuTag
            item.state = (space.id == activeID) ? .on : .off
            menu.insertItem(item, at: insertAt)
            insertAt += 1
        }

        let separator = NSMenuItem.separator()
        separator.tag = AppDelegate.spacesMenuTag
        menu.insertItem(separator, at: insertAt)
    }

    /// A space's Spaces-menu title: its emoji and name.
    private static func spacesMenuTitle(_ space: Space) -> String { "\(space.emoji) \(space.name)" }

    private func updateExtensionsMenu(_ menu: NSMenu) {
        // Remove previous dynamic extension items
        menu.items
            .filter { $0.tag == AppDelegate.extensionMenuTag }
            .forEach { menu.removeItem($0) }

        // Get extensions enabled for the current profile (the palette lists
        // the same, `ExtensionMenuItems`, TASK-320).
        let keyProfile = keyBrowserWindowController?.activeSpace?.profile
        let profileExtensions = ExtensionMenuItems.extensions(inProfile: keyBrowserWindowController?.activeSpace?.profileID)

        guard !profileExtensions.isEmpty else { return }

        // Insert extension items before the static items at the end: "Add
        // Extensions…", "Manage Extensions…", "Check for Extension Updates".
        let insertIndex = max(menu.items.count - AppDelegate.extensionsMenuStaticItemCount, 0)

        for (i, ext) in profileExtensions.enumerated() {
            let displayName = ExtensionManager.shared.displayName(for: ext.id)
            // Never read `action.popupWebView` here: it is created lazily, so
            // the read itself loads the extension's popup page (TASK-55). The
            // decision goes through a protocol that cannot see it. This rebuild
            // no longer runs on key-equivalent dispatch — `menuHasKeyEquivalent`
            // answers that (TASK-56) — but the guard stays: no rebuild, on open
            // or otherwise, may load popups.
            let hasPopup = ExtensionMenuItems.hasPopup(ext)
            // Options live in the key window's profile (TASK-103): offered only
            // when that profile holds a context to serve the page.
            let hasOptions = ExtensionMenuItems.hasOptions(ext, in: keyProfile)

            // The menu autoenables, so a nil action is what disables an item.
            // The parameterised `extension.show-popup` and `extension.options`
            // commands, for this extension.
            let popupItem = NSMenuItem(
                title: BrowserCommands.showExtensionPopup.title,
                action: hasPopup ? BrowserCommands.showExtensionPopup.action : nil,
                keyEquivalent: ""
            )
            let optionsItem = NSMenuItem(
                title: BrowserCommands.extensionOptions.title,
                action: hasOptions ? BrowserCommands.extensionOptions.action : nil,
                keyEquivalent: ""
            )
            let submenu = NSMenu(title: displayName)
            for child in [popupItem, optionsItem] {
                child.target = self
                child.representedObject = ext.id
                child.tag = AppDelegate.extensionMenuTag
                submenu.addItem(child)
            }

            let item = NSMenuItem(title: displayName, action: nil, keyEquivalent: "")
            item.representedObject = ext.id
            item.tag = AppDelegate.extensionMenuTag
            item.submenu = submenu

            if let icon = ext.icon {
                let size = NSSize(width: 16, height: 16)
                item.image = NSImage(size: size, flipped: false) { rect in
                    icon.draw(in: rect)
                    return true
                }
            } else {
                item.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: displayName)
            }

            menu.insertItem(item, at: insertIndex + i)
        }

        let separator = NSMenuItem.separator()
        separator.tag = AppDelegate.extensionMenuTag
        menu.insertItem(separator, at: insertIndex + profileExtensions.count)
    }

    /// Rebuilds the Develop menu's per-extension inspector items. Driven by
    /// `extensionsDidChangeNotification` (and once at setup), not by
    /// `menuNeedsUpdate`: the Develop menu has no delegate.
    private func updateDevelopMenu(_ menu: NSMenu) {
        // Remove previous extension inspector items
        menu.items
            .filter { $0.tag == AppDelegate.extensionInspectorTag }
            .forEach { menu.removeItem($0) }

        defer { addUnpackedReloadItems(to: menu) }

        let extensions = ExtensionManager.shared.enabledExtensions
        guard !extensions.isEmpty else { return }

        let separator = NSMenuItem.separator()
        separator.tag = AppDelegate.extensionInspectorTag
        menu.addItem(separator)

        for ext in extensions {
            let displayName = ExtensionManager.shared.displayName(for: ext.id)
            // The parameterised `extension.inspect-offscreen` command.
            let item = NSMenuItem(
                title: "Inspect \"\(displayName)\" Offscreen",
                action: BrowserCommands.inspectExtensionOffscreen.action,
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = ext.id
            item.tag = AppDelegate.extensionInspectorTag
            menu.addItem(item)
        }
    }

    /// Develop > Reload "<name>" for every unpacked extension, enabled or not
    /// (TASK-113). Reads only the extension list and the file system — never an
    /// extension page (TASK-55). A nil action (the menu autoenables) disables
    /// the item when the source folder is not recorded or has no manifest.
    private func addUnpackedReloadItems(to menu: NSMenu) {
        let unpacked = ExtensionManager.shared.extensions.filter { $0.source == .unpacked }
        guard !unpacked.isEmpty else { return }

        let separator = NSMenuItem.separator()
        separator.tag = AppDelegate.extensionInspectorTag
        menu.addItem(separator)

        for ext in unpacked {
            let displayName = ExtensionManager.shared.displayName(for: ext.id)
            let unavailableReason = ext.unpackedReloadUnavailableReason
            // The parameterised `extension.reload-unpacked` command.
            let item = NSMenuItem(
                title: "Reload \"\(displayName)\"",
                action: unavailableReason == nil ? BrowserCommands.reloadUnpackedExtension.action : nil,
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = ext.id
            item.tag = AppDelegate.extensionInspectorTag
            item.toolTip = unavailableReason
            menu.addItem(item)
        }
    }

    @MainActor @objc func reloadUnpackedExtension(_ sender: NSMenuItem) {
        guard let extID = sender.representedObject as? String else { return }
        do {
            let result = try ExtensionManager.shared.reloadUnpacked(id: extID)
            if case .installedPendingPermissions = result {
                let name = ExtensionManager.shared.displayName(for: extID)
                NSApp.frontmostBrowserWindowController?.toastManager.show(
                    message: "Reloaded \(name) — approve its new permissions in Settings")
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to Reload Extension"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    /// Extensions > Check for Extension Updates: a full check now, with a
    /// non-blocking summary toast in the frontmost browser window.
    @objc func checkForExtensionUpdates() {
        Task { @MainActor in
            let outcomes = await ExtensionUpdater.shared.checkAllForUpdates()
            let message = AppDelegate.updateCheckSummary(outcomes)
            log.notice("Manual extension update check: \(message, privacy: .public)")
            NSApp.frontmostBrowserWindowController?.toastManager.show(message: message)
        }
    }

    /// One line summing up a full update check.
    static func updateCheckSummary(_ outcomes: [String: ExtensionUpdateOutcome]) -> String {
        var updated = 0, pending = 0, failed = 0, checked = 0, deferred = 0
        for outcome in outcomes.values {
            switch outcome {
            case .updated: updated += 1; checked += 1
            case .updatedPendingPermissions: updated += 1; pending += 1; checked += 1
            case .deferred: deferred += 1; checked += 1
            case .failed: failed += 1; checked += 1
            case .upToDate, .throttled: checked += 1
            case .notUpdatable: break
            }
        }
        if checked == 0 { return "No extensions to update" }
        var parts: [String] = []
        if updated == 0 && deferred == 0 {
            parts.append("Extensions are up to date")
        } else if updated > 0 {
            parts.append(updated == 1 ? "1 extension updated" : "\(updated) extensions updated")
        }
        if deferred > 0 { parts.append("\(deferred) install\(deferred == 1 ? "s" : "") when idle") }
        if pending > 0 { parts.append("\(pending) need\(pending == 1 ? "s" : "") permission approval") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }

}

extension NSApplication {
    /// Every browser window controller, front to back: the key window's first,
    /// then the main window's, then the rest in `orderedWindows` order, each
    /// once. Windows that are not browser windows (Settings, panels) are
    /// skipped, so with Settings key and main this still starts at the browser
    /// window right behind it.
    ///
    /// Closed windows are skipped too. `orderedWindows` keeps listing a closed
    /// window for as long as anything holds it, and a link placed in one would
    /// show it again, cut off from the store (TASK-314). The test is the
    /// controller's own `hasClosed`, not `isVisible`: a miniaturized window, or
    /// any window while the app is hidden, is not visible but still counts.
    var browserWindowControllersFrontToBack: [BrowserWindowController] {
        var seen = Set<ObjectIdentifier>()
        return ([keyWindow, mainWindow].compactMap { $0 } + orderedWindows)
            .compactMap { $0.windowController as? BrowserWindowController }
            .filter { !$0.hasClosed && seen.insert(ObjectIdentifier($0)).inserted }
    }

    /// The browser window the user is looking at (or was, when a non-browser
    /// window such as Settings is in front).
    var frontmostBrowserWindowController: BrowserWindowController? {
        browserWindowControllersFrontToBack.first
    }
}
