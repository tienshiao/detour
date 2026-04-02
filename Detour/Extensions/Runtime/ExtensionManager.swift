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

    /// The most recently focused space ID, used for `currentWindow` queries.
    var lastActiveSpaceID: UUID?

    let tabObserver = ExtensionTabObserver()

    /// Stored popup completionHandlers for extension-initiated popups (browser.action.openPopup).
    private var popupCompletionHandlers: [String: ((any Error)?) -> Void] = [:]

    /// Retained popover controllers for extension-initiated popups.
    private var activePopovers: [String: ExtensionPopoverController] = [:]

    /// Retained native messaging hosts for one-shot sendMessage calls.
    private var activeMessagingHosts: [ObjectIdentifier: NativeMessagingHost] = [:]

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

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification, object: nil
        )
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let wc = window.windowController as? BrowserWindowController else { return }
        for profile in TabStore.shared.profiles {
            profile.extensionController.didFocusWindow(wc)
        }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        // Defer check: NSApp.keyWindow hasn't updated yet in the same run loop pass
        DispatchQueue.main.async {
            if NSApp.keyWindow?.windowController is BrowserWindowController { return }
            for profile in TabStore.shared.profiles {
                profile.extensionController.didFocusWindow(nil)
            }
        }
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

        // Inject polyfills into each extension before loading
        for ext in pendingExtensions {
            injectServiceWorkerPolyfill(into: ext)
            writeContentPolyfill(into: ext)
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
            loadExtensionsIntoProfile(profile)
        }

        invalidateEnabledExtensionsCache()
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
    }

    /// Load all globally-enabled extensions into a profile's controller (respecting per-profile disabling).
    @MainActor
    func loadExtensionsIntoProfile(_ profile: Profile) {
        let enabledIDs = AppDatabase.shared.enabledExtensionIDs(for: profile.id.uuidString)
        log.info("Loading extensions for profile \(profile.name, privacy: .public), enabledIDs: \(enabledIDs, privacy: .public)")

        // Load all contexts. Background content loads on demand when needed.
        for ext in extensions where enabledIDs.contains(ext.id) {
            profile.loadExtensionContext(ext)
        }

        notifyExistingTabs(for: profile)
    }

    private func notifyExistingTabs(for profile: Profile) {
        let controller = profile.extensionController
        let windowControllers = NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }
            .filter { $0.activeSpace?.profileID == profile.id }

        for wc in windowControllers {
            controller.didOpenWindow(wc)
        }

        // Report ALL tabs across ALL spaces for this profile, not just the active space.
        // WKWebExtension uses didOpenTab to associate web views with WKWebExtensionTab objects;
        // without this, sender.tab is null for content script messages from non-active spaces.
        // Report non-sleeping tabs across all spaces for this profile.
        // Sleeping tabs have no webView and can't run content scripts.
        let profileSpaces = TabStore.shared.spaces.filter { $0.profileID == profile.id }
        for space in profileSpaces {
            for tab in space.pinnedTabs + space.tabs where !tab.isSleeping {
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
            extensions.remove(at: existingIdx)
        }

        extensions.append(ext)

        // Save all declared permissions as granted in the DB so they're
        // restored on subsequent launches without re-prompting.
        var permRecords: [ExtensionPermissionRecord] = []
        for perm in ext.manifest.permissions ?? [] {
            permRecords.append(ExtensionPermissionRecord(
                extensionID: ext.id, key: perm, type: .apiPermission, status: .granted
            ))
        }
        for pattern in ext.manifest.hostPermissions ?? [] {
            permRecords.append(ExtensionPermissionRecord(
                extensionID: ext.id, key: pattern, type: .matchPattern, status: .granted
            ))
        }
        if !permRecords.isEmpty {
            AppDatabase.shared.savePermissions(permRecords)
        }

        // Inject polyfills before WKWebExtension reads the files
        injectServiceWorkerPolyfill(into: ext)
        writeContentPolyfill(into: ext)

        // Load via WKWebExtension asynchronously, then into all profiles
        Task { @MainActor in
            do {
                ext.wkExtension = try await WKWebExtension(resourceBaseURL: ext.basePath)

                for profile in TabStore.shared.profiles {
                    let enabledIDs = AppDatabase.shared.enabledExtensionIDs(for: profile.id.uuidString)
                    if enabledIDs.contains(ext.id) {
                        profile.loadExtension(ext)
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

        // Unload from all profiles
        for profile in TabStore.shared.profiles {
            profile.unloadExtension(id: id)
        }

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

        Task { @MainActor in
            for profile in TabStore.shared.profiles {
                if enabled {
                    profile.loadExtension(ext)
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

        // Load/unload in the specific profile
        if let profile = TabStore.shared.profiles.first(where: { $0.id == profileID }),
           let ext = self.extension(withID: id) {
            Task { @MainActor in
                if enabled {
                    profile.loadExtension(ext)
                    notifyExistingTabs(for: profile)
                } else {
                    profile.unloadExtension(id: id)
                }
            }
        }

        invalidateEnabledExtensionsCache()
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
    }


    // MARK: - Tab Activation

    @objc private func handleTabActivated(_ notification: Notification) {
        guard let info = notification.userInfo,
              let tabID = info["tabID"] as? UUID,
              let spaceID = info["spaceID"] as? UUID else { return }
        tabObserver.dispatchActivated(tabID: tabID, spaceID: spaceID)
    }

    // MARK: - Service Worker Polyfill Injection

    /// When true, module service workers are bundled into a single classic script
    /// via ModuleBundler. When false, the polyfill is injected as an ES module import.
    /// Bundling provides better scope isolation for polyfill patches but is more
    /// invasive. The module-import approach is simpler and less likely to break.
    private static let useModuleBundler = false

    private func injectServiceWorkerPolyfill(into ext: WebExtension) {
        guard let swFile = ext.manifest.background?.serviceWorker else { return }
        let polyfillFilename = "_detour_polyfill.js"
        let swURL = ext.basePath.appendingPathComponent(swFile)

        if ext.manifest.background?.isModule == true {
            if Self.useModuleBundler {
                do {
                    try ModuleBundler.bundle(extension: ext)
                    return
                } catch {
                    log.error("Bundler failed for \(ext.id, privacy: .public): \(error.localizedDescription, privacy: .public), falling back to module import")
                }
            }
            injectModuleSWPolyfill(ext: ext, swURL: swURL)
            return
        }

        // Classic service workers: write polyfill file + importScripts
        injectClassicSWPolyfill(ext: ext, swURL: swURL, polyfillFilename: polyfillFilename)
    }

    private func injectClassicSWPolyfill(ext: WebExtension, swURL: URL, polyfillFilename: String) {
        // Write the polyfill file next to the service worker, since importScripts
        // resolves paths relative to the SW file's directory, not the extension root.
        let swDir = swURL.deletingLastPathComponent()
        let polyfillURL = swDir.appendingPathComponent(polyfillFilename)
        do {
            try writeIfChanged(ExtensionAPIPolyfill.polyfillJS, to: polyfillURL)
        } catch {
            log.error("Failed to write polyfill for \(ext.id, privacy: .public): \(error.localizedDescription)")
            return
        }

        let importLine = "importScripts('\(polyfillFilename)');"
        do {
            let swSource = try String(contentsOf: swURL, encoding: .utf8)
            if !swSource.contains(importLine) {
                let patched = importLine + "\n" + swSource
                try patched.write(to: swURL, atomically: true, encoding: .utf8)
                log.info("Injected polyfill into classic SW for \(ext.id, privacy: .public)")
            }
        } catch {
            log.error("Failed to patch classic SW for \(ext.id, privacy: .public): \(error.localizedDescription)")
        }
    }

    private func injectModuleSWPolyfill(ext: WebExtension, swURL: URL) {
        let polyfillFilename = "_detour_polyfill_module.js"
        // Write the polyfill file next to the service worker, matching the classic strategy.
        let swDir = swURL.deletingLastPathComponent()
        let polyfillURL = swDir.appendingPathComponent(polyfillFilename)
        do {
            try writeIfChanged(ExtensionAPIPolyfill.polyfillJS, to: polyfillURL)
        } catch {
            log.error("Failed to write module SW polyfill for \(ext.id, privacy: .public): \(error.localizedDescription)")
            return
        }

        let importLine = "import './\(polyfillFilename)';"
        do {
            let swSource = try String(contentsOf: swURL, encoding: .utf8)
            if !swSource.contains(importLine) {
                let patched = importLine + "\n" + swSource
                try patched.write(to: swURL, atomically: true, encoding: .utf8)
                log.info("Injected polyfill module into module SW for \(ext.id, privacy: .public)")
            }
        } catch {
            log.error("Failed to patch module SW for \(ext.id, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// Writes the content polyfill file and inserts it as the first script in each
    /// content_scripts entry in the manifest, so it runs before the extension's own scripts.
    private func writeContentPolyfill(into ext: WebExtension) {
        let filename = "_detour_content_polyfill.js"
        let fileURL = ext.basePath.appendingPathComponent(filename)

        // Write the polyfill file (update if changed)
        do {
            try writeIfChanged(ExtensionAPIPolyfill.contentPolyfillJS, to: fileURL)
        } catch {
            log.error("Failed to write content polyfill for \(ext.id, privacy: .public): \(error.localizedDescription)")
            return
        }

        // Insert polyfill as first script in each content_scripts entry in manifest.json
        let manifestURL = ext.basePath.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              var contentScripts = manifest["content_scripts"] as? [[String: Any]] else { return }

        var modified = false
        for i in contentScripts.indices {
            guard var jsFiles = contentScripts[i]["js"] as? [String] else { continue }
            if !jsFiles.contains(filename) {
                jsFiles.insert(filename, at: 0)
                contentScripts[i]["js"] = jsFiles
                modified = true
            }
        }

        if modified {
            manifest["content_scripts"] = contentScripts
            if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: manifestURL, options: .atomic)
                log.info("Injected content polyfill into manifest for \(ext.id, privacy: .public)")
            }
        }
    }

    // MARK: - Helpers

    /// Write content to a file only if it differs from the existing content.
    private func writeIfChanged(_ content: String, to url: URL) throws {
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard existing != content else { return }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Find the profile that owns a given controller.
    private func profile(for controller: WKWebExtensionController) -> Profile? {
        TabStore.shared.profiles.first { $0.extensionController === controller }
    }

    /// Find a space belonging to the profile that owns a controller.
    /// Returns nil if the profile has no open spaces — callers should not create
    /// tabs in a different profile's space.
    private func space(for controller: WKWebExtensionController) -> Space? {
        let targetProfile = profile(for: controller)
        return TabStore.shared.spaces.first { $0.profileID == targetProfile?.id }
    }

    /// Select a tab and notify window controllers.
    private func selectTab(_ tab: BrowserTab, in space: Space) {
        space.selectedTabID = tab.id
        NotificationCenter.default.post(
            name: Self.tabShouldSelectNotification,
            object: nil,
            userInfo: ["tabID": tab.id, "spaceID": space.id]
        )
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
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let optionsURL = extensionContext.optionsPageURL,
              let extConfig = extensionContext.webViewConfiguration,
              let space = space(for: controller) else {
            completionHandler(nil)
            return
        }

        let tab = TabStore.shared.addExtensionTab(in: space, url: optionsURL, configuration: extConfig)
        selectTab(tab, in: space)
        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let space = space(for: controller) else {
            completionHandler(nil, nil)
            return
        }

        let url = configuration.url ?? URL(string: "about:blank")!
        let tab: BrowserTab
        if url.scheme == "webkit-extension", let extConfig = extensionContext.webViewConfiguration {
            tab = TabStore.shared.addExtensionTab(in: space, url: url, configuration: extConfig)
        } else {
            tab = TabStore.shared.addTab(in: space, url: url)
        }

        if configuration.shouldBeActive {
            selectTab(tab, in: space)
        }
        completionHandler(tab, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            completionHandler(nil, nil)
            return
        }

        let wc = BrowserWindowController(incognito: configuration.shouldBePrivate)
        appDelegate.assignDefaultSpace(to: wc)

        // TODO: Handle configuration.tabs (moving existing tabs to new window)

        // Open new tabs for specified URLs
        var lastTab: BrowserTab?
        if let space = wc.activeSpace {
            for url in configuration.tabURLs {
                if url.scheme == "webkit-extension", let extConfig = extensionContext.webViewConfiguration {
                    lastTab = TabStore.shared.addExtensionTab(in: space, url: url, configuration: extConfig)
                } else {
                    lastTab = TabStore.shared.addTab(in: space, url: url)
                }
            }
        }

        wc.showWindow(nil)
        if let lastTab {
            wc.selectTab(id: lastTab.id)
        } else if configuration.tabURLs.isEmpty && configuration.tabs.isEmpty {
            wc.newTab(nil)
        }

        appDelegate.registerWindowController(wc)

        if configuration.shouldBeFocused {
            wc.window?.makeKeyAndOrderFront(nil)
        }

        // Apply window frame if specified (NaN means not specified)
        let frame = configuration.frame
        if let window = wc.window {
            var currentFrame = window.frame
            if !frame.origin.x.isNaN { currentFrame.origin.x = frame.origin.x }
            if !frame.origin.y.isNaN { currentFrame.origin.y = frame.origin.y }
            if !frame.size.width.isNaN { currentFrame.size.width = frame.size.width }
            if !frame.size.height.isNaN { currentFrame.size.height = frame.size.height }
            if currentFrame != window.frame {
                window.setFrame(currentFrame, display: true)
            }
        }

        completionHandler(wc, nil)
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
        let extID = extensionIDFromContext(extensionContext)
        let name = extID.map { displayName(for: $0) } ?? "This extension"
        let descriptions = permissions.map { ExtensionPermissionDescriptions.describe($0.rawValue) }

        let granted = promptUserForPermission(
            extensionName: name,
            itemDescriptions: descriptions
        )

        if let extID {
            let status: ExtensionPermissionStatus = granted ? .granted : .denied
            let records = permissions.map {
                ExtensionPermissionRecord(extensionID: extID, key: $0.rawValue, type: .apiPermission, status: status)
            }
            AppDatabase.shared.savePermissions(records)
        }
        completionHandler(granted ? permissions : Set(), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let extID = extensionIDFromContext(extensionContext)
        let name = extID.map { displayName(for: $0) } ?? "This extension"
        let descriptions = urls.map { $0.absoluteString }

        let granted = promptUserForPermission(
            extensionName: name,
            itemDescriptions: descriptions,
            category: "site access"
        )

        if let extID {
            let status: ExtensionPermissionStatus = granted ? .granted : .denied
            let records = urls.map {
                ExtensionPermissionRecord(extensionID: extID, key: $0.absoluteString, type: .matchPattern, status: status)
            }
            AppDatabase.shared.savePermissions(records)
        }
        completionHandler(granted ? urls : Set(), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let extID = extensionIDFromContext(extensionContext)
        let name = extID.map { displayName(for: $0) } ?? "This extension"
        let descriptions = matchPatterns.map { pattern -> String in
            pattern.string == "<all_urls>" ? "All websites" : pattern.string
        }

        let granted = promptUserForPermission(
            extensionName: name,
            itemDescriptions: descriptions,
            category: "site access"
        )

        if let extID {
            let status: ExtensionPermissionStatus = granted ? .granted : .denied
            let records = matchPatterns.map {
                ExtensionPermissionRecord(extensionID: extID, key: $0.string, type: .matchPattern, status: status)
            }
            AppDatabase.shared.savePermissions(records)
        }
        completionHandler(granted ? matchPatterns : Set(), nil)
    }

    /// Shows an NSAlert prompting the user to allow or deny permissions.
    /// Returns true if the user clicked Allow.
    private func promptUserForPermission(
        extensionName: String,
        itemDescriptions: [String],
        category: String = "permissions"
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\"\(extensionName)\" is requesting additional \(category)"
        alert.informativeText = itemDescriptions.map { "\u{2022} \($0)" }.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        return alert.runModal() == .alertFirstButtonReturn
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
        // Route polyfill messages from service workers (where webkit.messageHandlers
        // is unavailable and the polyfill falls back to sendNativeMessage).
        if appID == ExtensionPolyfillHandler.handlerName,
           let body = message as? [String: Any] {
            log.debug("Routing polyfill native message: \(body["type"] as? String ?? "(no type)", privacy: .public)")
            let profile = profile(for: controller)
            if let handler = profile?.polyfillHandler {
                handler.handleNativeMessage(body, replyHandler: replyHandler)
            } else {
                log.error("No polyfill handler for profile")
                replyHandler(nil, NSError(domain: "DetourPolyfill", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: "No polyfill handler for profile"]))
            }
            return
        }

        log.info("sendNativeMessage to appID: \(appID ?? "(nil)", privacy: .public)")

        guard let hostName = appID,
              let extID = extensionIDFromContext(extensionContext) else {
            replyHandler(nil, nil)
            return
        }

        // nativeMessaging is auto-granted so the polyfill bridge works, but
        // real native messaging hosts should only be reachable by extensions
        // that explicitly declared the permission in their manifest.
        let ext = self.extension(withID: extID)
        let manifestPermissions = ext?.manifest.permissions ?? []
        if !manifestPermissions.contains("nativeMessaging") {
            log.warning("Extension \(extID, privacy: .public) tried native messaging to '\(hostName, privacy: .public)' without declaring nativeMessaging permission")
            replyHandler(nil, NSError(domain: "DetourExtension", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "nativeMessaging permission not declared"]))
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
