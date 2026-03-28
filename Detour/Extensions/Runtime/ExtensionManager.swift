import Foundation
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-manager")

/// Singleton lifecycle manager for web extensions.
/// Each `Profile` owns its own `WKWebExtensionController`; this class coordinates
/// install/uninstall/enable/disable across profiles and serves as the delegate for all controllers.
class ExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    static let shared = ExtensionManager()

    /// Model array for UI (settings, toolbar, menus). Single source of truth.
    /// Each element's `.wkExtension` is populated asynchronously after init.
    var extensions: [WebExtension] = []

    /// Context menu items registered by extensions via chrome.contextMenus.
    var contextMenuItems: [String: [ContextMenuItem]] = [:]

    /// Uninstall URLs per extension, set via chrome.runtime.setUninstallURL.
    var uninstallURLs: [String: URL] = [:]

    /// The most recently focused space ID, used for `currentWindow` queries.
    var lastActiveSpaceID: UUID?

    let tabObserver = ExtensionTabObserver()

    /// Stored popup completionHandlers for extension-initiated popups (browser.action.openPopup).
    private var popupCompletionHandlers: [String: ((any Error)?) -> Void] = [:]

    /// Retained popover controllers for extension-initiated popups.
    private var activePopovers: [String: ExtensionPopoverController] = [:]

    /// Retained native messaging hosts for one-shot sendMessage calls.
    private var activeMessagingHosts: [ObjectIdentifier: NativeMessagingHost] = [:]

    /// Background loading tasks, keyed by extensionID, for cancellation on unload.
    private var backgroundLoadTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Notifications

    static let extensionsDidChangeNotification = Notification.Name("ExtensionManagerExtensionsDidChange")
    static let tabShouldSelectNotification = Notification.Name("extensionTabShouldSelect")
    static let tabActivatedNotification = Notification.Name("extensionTabActivated")
    static let popupOpenURLNotification = Notification.Name("extensionPopupOpenURL")
    static let openOptionsPageNotification = Notification.Name("extensionOpenOptionsPage")
    static let extensionActionDidChangeNotification = Notification.Name("extensionActionDidChange")

    // MARK: - Init

    override init() {
        super.init()
    }

    // MARK: - Initialize

    func initialize() {
        Task { @MainActor in
            await loadInstalledExtensions()
        }

        TabStore.shared.addObserver(tabObserver)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTabActivated(_:)),
            name: Self.tabActivatedNotification, object: nil
        )
    }

    @MainActor
    private func loadInstalledExtensions() async {
        let records = AppDatabase.shared.loadExtensions()

        // Parse manifests and create models (fast, synchronous)
        var pendingExtensions: [WebExtension] = []
        for record in records {
            let basePath = URL(fileURLWithPath: record.basePath)
            let diskManifestURL = basePath.appendingPathComponent("manifest.json")
            let manifest: ExtensionManifest
            if let diskManifest = try? ExtensionManifest.parse(at: diskManifestURL) {
                manifest = diskManifest
            } else if let dbManifest = try? JSONDecoder().decode(ExtensionManifest.self, from: record.manifestJSON) {
                manifest = dbManifest
            } else {
                log.error("Failed to decode manifest for extension \(record.id, privacy: .public)")
                continue
            }

            let ext = WebExtension(id: record.id, manifest: manifest, basePath: basePath, isEnabled: record.isEnabled)
            pendingExtensions.append(ext)
        }

        // Load WKWebExtension resources in parallel (async I/O)
        await withTaskGroup(of: (WebExtension, WKWebExtension?).self) { group in
            for ext in pendingExtensions {
                group.addTask { @MainActor in
                    do {
                        let wkExt = try await WKWebExtension(resourceBaseURL: ext.basePath)
                        return (ext, wkExt)
                    } catch {
                        log.error("Failed to load WKWebExtension for \(ext.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return (ext, nil)
                    }
                }
            }
            for await (ext, wkExt) in group {
                ext.wkExtension = wkExt
                extensions.append(ext)
                log.info("Loaded extension \(ext.manifest.name, privacy: .public) (\(ext.id, privacy: .public)), enabled: \(ext.isEnabled)")
            }
        }

        // Load enabled extensions into each profile's controller
        // (notifyExistingTabs is called inside loadExtensionsIntoProfile after contexts are registered)
        for profile in TabStore.shared.profiles {
            await loadExtensionsIntoProfile(profile)
        }

        invalidateEnabledExtensionsCache()
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
    }

    /// Load all globally-enabled extensions into a profile's controller (respecting per-profile disabling).
    @MainActor
    func loadExtensionsIntoProfile(_ profile: Profile) async {
        let enabledIDs = AppDatabase.shared.enabledExtensionIDs(for: profile.id.uuidString)
        log.info("Loading extensions for profile \(profile.name, privacy: .public), enabledIDs: \(enabledIDs, privacy: .public)")

        // Phase 1: Load all contexts (fast, synchronous)
        var needsBackground: [WebExtension] = []
        for ext in extensions where enabledIDs.contains(ext.id) {
            if profile.loadExtensionContext(ext) {
                needsBackground.append(ext)
            }
        }

        // Phase 2: Notify existing tabs (must happen after contexts are registered)
        notifyExistingTabs(for: profile)

        // Phase 3: Start background content in parallel (can be slow/hang)
        for ext in needsBackground {
            let task = Task { @MainActor in
                await profile.startBackgroundContent(for: ext)
                self.backgroundLoadTasks.removeValue(forKey: ext.id)
            }
            backgroundLoadTasks[ext.id] = task
        }
    }

    private func notifyExistingTabs(for profile: Profile) {
        let controller = profile.extensionController
        let windowControllers = NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }
            .filter { $0.activeSpace?.profileID == profile.id }

        for wc in windowControllers {
            controller.didOpenWindow(wc)
            for tab in (wc.activeSpace?.pinnedTabs ?? []) + wc.currentTabs {
                for context in profile.extensionContexts.values {
                    context.didOpenTab(tab)
                }
            }
        }

        if let focusedWC = NSApp.keyWindow?.windowController as? BrowserWindowController,
           focusedWC.activeSpace?.profileID == profile.id {
            controller.didFocusWindow(focusedWC)
            if let activeTab = focusedWC.selectedTab {
                for context in profile.extensionContexts.values {
                    context.didActivateTab(activeTab, previousActiveTab: nil)
                }
            }
        }
    }

    // MARK: - Enabled Extensions

    var enabledExtensions: [WebExtension] {
        extensions.filter { $0.isEnabled }
    }

    private var enabledIDsCache: [UUID: Set<String>] = [:]

    func enabledExtensions(for profileID: UUID) -> [WebExtension] {
        let ids: Set<String>
        if let cached = enabledIDsCache[profileID] {
            ids = cached
        } else {
            ids = Set(AppDatabase.shared.enabledExtensionIDs(for: profileID.uuidString))
            enabledIDsCache[profileID] = ids
        }
        return extensions.filter { ids.contains($0.id) }
    }

    func invalidateEnabledExtensionsCache() {
        enabledIDsCache.removeAll()
    }

    func `extension`(withID id: String) -> WebExtension? {
        extensions.first { $0.id == id }
    }

    /// Find a context for an extension ID from the currently active profile.
    func context(for extensionID: String) -> WKWebExtensionContext? {
        if let spaceID = lastActiveSpaceID,
           let space = TabStore.shared.space(withID: spaceID),
           let profile = space.profile {
            return profile.extensionContext(for: extensionID)
        }
        // Fallback: search all profiles
        for profile in TabStore.shared.profiles {
            if let ctx = profile.extensionContext(for: extensionID) {
                return ctx
            }
        }
        return nil
    }

    /// Localized display name for an extension.
    func displayName(for extensionID: String) -> String {
        if let ext = self.extension(withID: extensionID) {
            if let nativeName = ext.wkExtension?.displayName, !nativeName.isEmpty {
                return nativeName
            }
            return ext.resolveI18n(ext.manifest.name)
        }
        return extensionID
    }

    /// Localized display description for an extension.
    func displayDescription(for extensionID: String) -> String? {
        if let ext = self.extension(withID: extensionID) {
            if let nativeDesc = ext.wkExtension?.displayDescription, !nativeDesc.isEmpty {
                return nativeDesc
            }
            if let desc = ext.manifest.description {
                return ext.resolveI18n(desc)
            }
        }
        return nil
    }

    // MARK: - Install

    @discardableResult
    func install(from sourceURL: URL, publicKey: Data? = nil) throws -> WebExtension {
        let ext = try ExtensionInstaller.install(from: sourceURL, publicKey: publicKey)

        // Clean up existing extension with same ID
        if let existingIdx = extensions.firstIndex(where: { $0.id == ext.id }) {
            for profile in TabStore.shared.profiles {
                profile.unloadExtension(id: ext.id)
            }
            contextMenuItems.removeValue(forKey: ext.id)
            extensions.remove(at: existingIdx)
        }

        extensions.append(ext)

        // Load via WKWebExtension asynchronously, then into all profiles
        Task { @MainActor in
            do {
                ext.wkExtension = try await WKWebExtension(resourceBaseURL: ext.basePath)

                for profile in TabStore.shared.profiles {
                    let enabledIDs = AppDatabase.shared.enabledExtensionIDs(for: profile.id.uuidString)
                    if enabledIDs.contains(ext.id) {
                        await profile.loadExtension(ext)
                    }
                }

                // Notify existing tabs in relevant profiles
                for profile in TabStore.shared.profiles {
                    if profile.extensionContext(for: ext.id) != nil {
                        notifyExistingTabs(for: profile)
                    }
                }
            } catch {
                log.error("Failed to load WKWebExtension after install: \(error.localizedDescription, privacy: .public)")
            }
        }

        invalidateEnabledExtensionsCache()
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
        return ext
    }

    // MARK: - Uninstall

    func uninstall(id: String) {
        log.info("Uninstalling extension \(id, privacy: .public)")

        // Open uninstall URL if set
        if let uninstallURL = uninstallURLs[id] {
            if let activeSpaceID = lastActiveSpaceID,
               let space = TabStore.shared.space(withID: activeSpaceID) {
                let tab = TabStore.shared.addTab(in: space, url: uninstallURL)
                space.selectedTabID = tab.id
                NotificationCenter.default.post(
                    name: Self.tabShouldSelectNotification,
                    object: nil,
                    userInfo: ["tabID": tab.id, "spaceID": space.id]
                )
            } else if let space = TabStore.shared.spaces.first {
                let tab = TabStore.shared.addTab(in: space, url: uninstallURL)
                space.selectedTabID = tab.id
            }
        }

        // Cancel any pending background load and unload from all profiles
        backgroundLoadTasks.removeValue(forKey: id)?.cancel()
        for profile in TabStore.shared.profiles {
            profile.unloadExtension(id: id)
        }

        contextMenuItems.removeValue(forKey: id)
        uninstallURLs.removeValue(forKey: id)
        extensions.removeAll { $0.id == id }
        AppDatabase.shared.deleteExtension(id: id)

        let extDir = detourDataDirectory().appendingPathComponent("Extensions/\(id)")
        try? FileManager.default.removeItem(at: extDir)

        invalidateEnabledExtensionsCache()
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
    }

    // MARK: - Enable / Disable

    func setEnabled(id: String, enabled: Bool) {
        guard let ext = self.extension(withID: id) else { return }
        log.info("Extension \(id, privacy: .public) \(enabled ? "enabled" : "disabled")")
        ext.isEnabled = enabled
        AppDatabase.shared.setEnabled(id: id, enabled: enabled)

        if !enabled {
            backgroundLoadTasks.removeValue(forKey: id)?.cancel()
        }

        Task { @MainActor in
            for profile in TabStore.shared.profiles {
                if enabled {
                    await profile.loadExtension(ext)
                    notifyExistingTabs(for: profile)
                } else {
                    profile.unloadExtension(id: id)
                }
            }
        }

        invalidateEnabledExtensionsCache()
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
    }

    func setEnabled(id: String, profileID: UUID, enabled: Bool) {
        AppDatabase.shared.setProfileExtensionEnabled(extensionID: id, profileID: profileID.uuidString, enabled: enabled)

        if !enabled {
            backgroundLoadTasks.removeValue(forKey: id)?.cancel()
        }

        // Load/unload in the specific profile
        if let profile = TabStore.shared.profiles.first(where: { $0.id == profileID }),
           let ext = self.extension(withID: id) {
            Task { @MainActor in
                if enabled {
                    await profile.loadExtension(ext)
                    notifyExistingTabs(for: profile)
                } else {
                    profile.unloadExtension(id: id)
                }
            }
        }

        invalidateEnabledExtensionsCache()
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
    }

    // MARK: - Context Menu Items

    func addContextMenuItem(_ item: ContextMenuItem, for extensionID: String) {
        if contextMenuItems[extensionID] == nil {
            contextMenuItems[extensionID] = []
        }
        contextMenuItems[extensionID]?.removeAll { $0.id == item.id }
        contextMenuItems[extensionID]?.append(item)
    }

    func updateContextMenuItem(id: String, properties: [String: Any], for extensionID: String) {
        guard let index = contextMenuItems[extensionID]?.firstIndex(where: { $0.id == id }) else { return }
        var item = contextMenuItems[extensionID]![index]
        if let title = properties["title"] as? String { item.title = title }
        if let contexts = properties["contexts"] as? [String] { item.contexts = contexts }
        contextMenuItems[extensionID]![index] = item
    }

    func removeContextMenuItem(id: String, for extensionID: String) {
        contextMenuItems[extensionID]?.removeAll { $0.id == id }
    }

    func removeAllContextMenuItems(for extensionID: String) {
        contextMenuItems.removeValue(forKey: extensionID)
    }

    var allContextMenuItems: [(item: ContextMenuItem, extensionID: String)] {
        contextMenuItems.flatMap { (extID, items) in
            items.map { ($0, extID) }
        }
    }

    // MARK: - Tab Activation

    @objc private func handleTabActivated(_ notification: Notification) {
        guard let info = notification.userInfo,
              let tabID = info["tabID"] as? UUID,
              let spaceID = info["spaceID"] as? UUID else { return }
        tabObserver.dispatchActivated(tabID: tabID, spaceID: spaceID)
    }

    // MARK: - Helpers

    /// Find the profile that owns a given controller.
    private func profile(for controller: WKWebExtensionController) -> Profile? {
        TabStore.shared.profiles.first { $0.extensionController === controller }
    }

    /// Find the extension ID for a context by searching the owning profile.
    private func extensionIDFromContext(_ context: WKWebExtensionContext) -> String? {
        guard let controller = context.webExtensionController,
              let profile = profile(for: controller) else { return nil }
        return profile.extensionContexts.first { $0.value === context }?.key
    }

    // MARK: - WKWebExtensionControllerDelegate

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        // Return windows whose profile matches this controller
        let profile = profile(for: controller)
        return NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }
            .filter { $0.activeSpace?.profileID == profile?.id }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        guard let wc = NSApp.keyWindow?.windowController as? BrowserWindowController,
              let profile = profile(for: controller),
              wc.activeSpace?.profileID == profile.id else { return nil }
        return wc
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        // Find a space that uses this controller's profile
        let targetProfile = profile(for: controller)
        let space = TabStore.shared.spaces.first { $0.profileID == targetProfile?.id }
            ?? TabStore.shared.spaces.first

        guard let space else {
            completionHandler(nil, nil)
            return
        }

        let url = configuration.url ?? URL(string: "about:blank")!
        let tab = TabStore.shared.addTab(in: space, url: url)
        if configuration.shouldBeActive {
            space.selectedTabID = tab.id
            NotificationCenter.default.post(
                name: Self.tabShouldSelectNotification,
                object: nil,
                userInfo: ["tabID": tab.id, "spaceID": space.id]
            )
        }
        completionHandler(tab, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        // This delegate is for extension-initiated opens (browser.action.openPopup()),
        // NOT for user toolbar clicks (those use action.popupWebView directly).
        guard let popupWebView = action.popupWebView,
              let extID = extensionIDFromContext(extensionContext) else {
            completionHandler(nil)
            return
        }

        let popoverController = ExtensionPopoverController(extensionID: extID)

        // Anchor to toolbar button if available, otherwise top-right of window
        if let window = NSApp.keyWindow, let toolbar = window.toolbar {
            let identifier = NSToolbarItem.Identifier(ExtensionToolbarManager.itemIdentifierPrefix + extID)
            if let toolbarItem = toolbar.items.first(where: { $0.itemIdentifier == identifier }),
               let buttonView = toolbarItem.view {
                popoverController.setPositioning(relativeTo: buttonView.bounds, of: buttonView, preferredEdge: .maxY)
            }
        } else if let contentView = NSApp.keyWindow?.contentView {
            let rect = NSRect(x: contentView.bounds.maxX - 50, y: contentView.bounds.maxY - 10, width: 1, height: 1)
            popoverController.setPositioning(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }

        popoverController.onClose = { [weak self] in
            self?.activePopovers.removeValue(forKey: extID)
            self?.popupCompletionHandlers.removeValue(forKey: extID)?(nil)
        }
        popoverController.presentPopupWebView(popupWebView)

        activePopovers[extID] = popoverController
        popupCompletionHandlers[extID] = completionHandler
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        completionHandler(urls, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        completionHandler(matchPatterns, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext extensionContext: WKWebExtensionContext
    ) {
        if let extID = extensionIDFromContext(extensionContext) {
            NotificationCenter.default.post(
                name: Self.extensionActionDidChangeNotification,
                object: nil,
                userInfo: ["extensionID": extID]
            )
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier appID: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        guard let hostName = appID,
              let extID = extensionIDFromContext(extensionContext) else {
            replyHandler(nil, nil)
            return
        }

        let host = NativeMessagingHost(hostName: hostName, extensionID: extID)
        let hostKey = ObjectIdentifier(host)
        activeMessagingHosts[hostKey] = host

        host.onMessage = { [weak self] response in
            self?.activeMessagingHosts.removeValue(forKey: hostKey)
            replyHandler(response, nil)
        }
        host.onDisconnect = { [weak self] _ in
            self?.activeMessagingHosts.removeValue(forKey: hostKey)
        }
        do {
            try host.connect()
            if let msgDict = message as? [String: Any] {
                try host.sendMessage(msgDict)
            }
        } catch {
            activeMessagingHosts.removeValue(forKey: hostKey)
            replyHandler(nil, error)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let hostName = port.applicationIdentifier,
              let extID = extensionIDFromContext(extensionContext) else {
            completionHandler(nil)
            return
        }

        let host = NativeMessagingHost(hostName: hostName, extensionID: extID)
        host.onMessage = { response in
            port.sendMessage(response, completionHandler: nil)
        }
        host.onDisconnect = { _ in
            port.disconnect(throwing: nil)
        }
        port.messageHandler = { message, _ in
            if let msgDict = message as? [String: Any] {
                try? host.sendMessage(msgDict)
            }
        }
        port.disconnectHandler = { _ in
            host.disconnect()
        }
        do {
            try host.connect()
        } catch {
            completionHandler(error)
            return
        }
        completionHandler(nil)
    }
}
