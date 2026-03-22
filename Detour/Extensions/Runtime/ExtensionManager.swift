import Foundation
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-manager")

/// Singleton lifecycle manager for web extensions.
/// Owns the list of loaded extensions, their background hosts, and the content script injector.
class ExtensionManager {
    static let shared = ExtensionManager()

    var extensions: [WebExtension] = []
    var backgroundHosts: [String: BackgroundHost] = [:]
    var offscreenHosts: [String: OffscreenDocumentHost] = [:]
    var contextMenuItems: [String: [ContextMenuItem]] = [:]

    /// Open popup/options page webViews per extension, used for message broadcast.
    /// Uses a weak reference so popover dismissal automatically cleans up.
    private struct WeakWebView {
        weak var webView: WKWebView?
    }
    private var popupWebViews: [String: WeakWebView] = [:]

    func registerPopupWebView(_ webView: WKWebView, for extensionID: String) {
        popupWebViews[extensionID] = WeakWebView(webView: webView)
    }

    func unregisterPopupWebView(for extensionID: String) {
        popupWebViews.removeValue(forKey: extensionID)
    }

    func popupWebView(for extensionID: String) -> WKWebView? {
        popupWebViews[extensionID]?.webView
    }

    /// Badge text per extension, set via chrome.action.setBadgeText.
    var badgeText: [String: String] = [:]
    /// Badge background color per extension, set via chrome.action.setBadgeBackgroundColor.
    var badgeBackgroundColor: [String: NSColor] = [:]
    /// Custom toolbar icons per extension, set via chrome.action.setIcon.
    var customIcons: [String: NSImage] = [:]
    /// Custom action title per extension, set via chrome.action.setTitle.
    var actionTitle: [String: String] = [:]
    /// Uninstall URLs per extension, set via chrome.runtime.setUninstallURL.
    var uninstallURLs: [String: URL] = [:]
    /// Custom popup paths per extension, set via chrome.action.setPopup.
    var customPopupPaths: [String: String] = [:]

    /// In-memory session storage per extension. Cleared on app restart (matches Chrome behavior).
    /// Keyed by extensionID → (key → value).
    private var sessionStorage: [String: [String: Any]] = [:]

    func sessionStorageGet(extensionID: String, keys: [String]) -> [String: Any] {
        let store = sessionStorage[extensionID] ?? [:]
        var result: [String: Any] = [:]
        for key in keys {
            if let value = store[key] { result[key] = value }
        }
        return result
    }

    func sessionStorageGetAll(extensionID: String) -> [String: Any] {
        sessionStorage[extensionID] ?? [:]
    }

    func sessionStorageSet(extensionID: String, items: [String: Any]) {
        if sessionStorage[extensionID] == nil { sessionStorage[extensionID] = [:] }
        for (key, value) in items { sessionStorage[extensionID]![key] = value }
    }

    func sessionStorageRemove(extensionID: String, keys: [String]) {
        for key in keys { sessionStorage[extensionID]?.removeValue(forKey: key) }
    }

    func sessionStorageClear(extensionID: String) {
        sessionStorage.removeValue(forKey: extensionID)
    }

    let injector = ContentScriptInjector()
    let tabIDMap = ExtensionTabIDMap()
    let spaceIDMap = ExtensionTabIDMap()
    let tabObserver = ExtensionTabObserver()

    /// The most recently focused space ID, used for `currentWindow` queries.
    var lastActiveSpaceID: UUID?

    /// Notification posted when the set of enabled extensions changes.
    static let extensionsDidChangeNotification = Notification.Name("ExtensionManagerExtensionsDidChange")

    /// Notification posted when an extension requests tab selection.
    static let tabShouldSelectNotification = Notification.Name("extensionTabShouldSelect")

    /// Notification for tab activation events from the browser.
    static let tabActivatedNotification = Notification.Name("extensionTabActivated")

    /// Notification posted when an extension popup wants to open a URL in the browser.
    static let popupOpenURLNotification = Notification.Name("extensionPopupOpenURL")

    /// Notification posted when an extension requests its options page be opened.
    static let openOptionsPageNotification = Notification.Name("extensionOpenOptionsPage")

    /// Notification posted when an extension's action (badge/icon/title) changes.
    static let extensionActionDidChangeNotification = Notification.Name("extensionActionDidChange")

    init() {}

    /// Initialize: load installed extensions from the database and start enabled ones.
    func initialize() {
        log.info("Initializing extension manager")
        let records = AppDatabase.shared.loadExtensions()
        for record in records {
            let basePath = URL(fileURLWithPath: record.basePath)
            // Prefer the on-disk manifest.json (source of truth) over the stored blob,
            // which can go stale when ExtensionManifest gains new fields.
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
            extensions.append(ext)
            log.info("Loaded extension \(ext.manifest.name, privacy: .public) (\(ext.id, privacy: .public)), enabled: \(ext.isEnabled)")

            if ext.isEnabled {
                // Extensions loaded from DB were already installed — don't fire onInstalled again
                startBackground(for: ext, isFirstRun: false)
            }
        }

        // Register tab observer for chrome.tabs events
        TabStore.shared.addObserver(tabObserver)

        // Observe tab activation events from BrowserWindowController
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTabActivated(_:)),
            name: Self.tabActivatedNotification, object: nil
        )

        // Register keyboard shortcuts for extension commands
        registerCommandShortcuts()
    }

    /// All currently enabled extensions (global).
    var enabledExtensions: [WebExtension] {
        extensions.filter { $0.isEnabled }
    }

    /// Cache of enabled extension IDs per profile. Invalidated when extensions change.
    private var enabledIDsCache: [UUID: Set<String>] = [:]

    /// Extensions enabled for a specific profile (global AND per-profile).
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

    /// Look up an extension by ID.
    func `extension`(withID id: String) -> WebExtension? {
        extensions.first { $0.id == id }
    }

    /// Get the background host for an extension.
    func backgroundHost(for extensionID: String) -> BackgroundHost? {
        backgroundHosts[extensionID]
    }

    @objc private func handleTabActivated(_ notification: Notification) {
        guard let info = notification.userInfo,
              let tabID = info["tabID"] as? UUID,
              let spaceID = info["spaceID"] as? UUID else { return }
        tabObserver.dispatchActivated(tabID: tabID, spaceID: spaceID)
    }

    /// Fire a web navigation event to all background hosts.
    func fireWebNavigationEvent(_ eventName: String, details: [String: Any]) {
        guard let detailsData = try? JSONSerialization.data(withJSONObject: details),
              let detailsJSON = String(data: detailsData, encoding: .utf8) else { return }

        let js = "if (window.__extensionDispatchWebNavEvent) { window.__extensionDispatchWebNavEvent('\(eventName)', \(detailsJSON)); }"

        for ext in enabledExtensions {
            backgroundHost(for: ext.id)?.evaluateJavaScript(js)
        }
    }

    /// Inject content scripts into all existing tabs for a newly installed/enabled extension.
    /// Skips spaces where the extension is not enabled for that space's profile.
    func injectIntoExistingTabs(extension ext: WebExtension) {
        for space in TabStore.shared.spaces {
            let enabledIDs = AppDatabase.shared.enabledExtensionIDs(for: space.profileID.uuidString)
            guard enabledIDs.contains(ext.id) else { continue }

            for tab in space.tabs {
                injector.injectIntoExistingTab(tab, for: ext)
            }
            for entry in space.pinnedEntries {
                if let tab = entry.tab {
                    injector.injectIntoExistingTab(tab, for: ext)
                }
            }
        }
    }

    /// Install an extension from an unpacked directory.
    @discardableResult
    func install(from sourceURL: URL, publicKey: Data? = nil) throws -> WebExtension {
        let ext = try ExtensionInstaller.install(from: sourceURL, publicKey: publicKey)

        // If an extension with the same ID already exists (e.g. reinstall with Chrome-compatible
        // IDs derived from the same public key), clean up the old entry first.
        if let existingIdx = extensions.firstIndex(where: { $0.id == ext.id }) {
            let old = extensions[existingIdx]
            stopBackground(for: old.id)
            ExtensionMessageBridge.shared.disconnectAllNativeHosts(for: old.id)
            offscreenHosts[old.id]?.stop()
            offscreenHosts.removeValue(forKey: old.id)
            contextMenuItems.removeValue(forKey: old.id)
            extensions.remove(at: existingIdx)
        }

        extensions.append(ext)
        log.info("Installed extension \(ext.manifest.name, privacy: .public) (\(ext.id, privacy: .public))")
        // Wait for the background host to finish loading before injecting content scripts.
        // Content scripts may send runtime.sendMessage immediately, which requires the
        // background's __extensionDispatchMessage handler to be ready.
        startBackground(for: ext) { [weak self] in
            self?.injectIntoExistingTabs(extension: ext)
        }
        invalidateEnabledExtensionsCache()
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
        return ext
    }

    // MARK: - Context Menu Items

    func addContextMenuItem(_ item: ContextMenuItem, for extensionID: String) {
        if contextMenuItems[extensionID] == nil {
            contextMenuItems[extensionID] = []
        }
        // Replace if item with same ID already exists
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

    /// All context menu items across all extensions.
    var allContextMenuItems: [(item: ContextMenuItem, extensionID: String)] {
        contextMenuItems.flatMap { (extID, items) in
            items.map { ($0, extID) }
        }
    }

    /// Dispatch a context menu click to the extension's background host.
    func dispatchContextMenuClicked(menuItemId: String, info: [String: Any], tab: [String: Any], extensionID: String) {
        guard let infoData = try? JSONSerialization.data(withJSONObject: info),
              let infoJSON = String(data: infoData, encoding: .utf8),
              let tabData = try? JSONSerialization.data(withJSONObject: tab),
              let tabJSON = String(data: tabData, encoding: .utf8) else {
            log.error("dispatchContextMenuClicked: JSON serialization failed for extension \(extensionID, privacy: .public)")
            return
        }

        let js = "if (window.__extensionDispatchContextMenuClicked) { window.__extensionDispatchContextMenuClicked(\(infoJSON), \(tabJSON)); }"
        backgroundHost(for: extensionID)?.evaluateJavaScript(js)
    }

    /// Uninstall an extension.
    func uninstall(id: String) {
        log.info("Uninstalling extension \(id, privacy: .public)")
        // Open uninstall URL in a new Detour tab if set
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

        stopBackground(for: id)
        ExtensionMessageBridge.shared.disconnectAllNativeHosts(for: id)
        offscreenHosts[id]?.stop()
        offscreenHosts.removeValue(forKey: id)
        contextMenuItems.removeValue(forKey: id)
        badgeText.removeValue(forKey: id)
        badgeBackgroundColor.removeValue(forKey: id)
        customIcons.removeValue(forKey: id)
        actionTitle.removeValue(forKey: id)
        uninstallURLs.removeValue(forKey: id)
        customPopupPaths.removeValue(forKey: id)
        sessionStorage.removeValue(forKey: id)
        extensions.removeAll { $0.id == id }
        AppDatabase.shared.deleteExtension(id: id)

        // Remove extension files
        let extDir = detourDataDirectory().appendingPathComponent("Extensions/\(id)")
        try? FileManager.default.removeItem(at: extDir)

        invalidateEnabledExtensionsCache()
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
    }

    /// Enable or disable an extension globally.
    func setEnabled(id: String, enabled: Bool) {
        guard let ext = self.extension(withID: id) else { return }
        log.info("Extension \(id, privacy: .public) \(enabled ? "enabled" : "disabled")")
        ext.isEnabled = enabled
        AppDatabase.shared.setEnabled(id: id, enabled: enabled)

        if enabled {
            startBackground(for: ext)
        } else {
            stopBackground(for: id)
            ExtensionMessageBridge.shared.disconnectAllNativeHosts(for: id)
        }

        invalidateEnabledExtensionsCache()
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
    }

    /// Enable or disable an extension for a specific profile.
    func setEnabled(id: String, profileID: UUID, enabled: Bool) {
        AppDatabase.shared.setProfileExtensionEnabled(extensionID: id, profileID: profileID.uuidString, enabled: enabled)
        invalidateEnabledExtensionsCache()
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
    }

    // MARK: - Command Shortcuts

    private var commandMonitor: Any?

    /// Register keyboard shortcuts declared in extension manifests.
    func registerCommandShortcuts() {
        // Remove any existing monitor
        if let monitor = commandMonitor {
            NSEvent.removeMonitor(monitor)
            commandMonitor = nil
        }

        // Collect all commands from enabled extensions
        var shortcuts: [(extensionID: String, commandName: String, modifiers: NSEvent.ModifierFlags, keyCode: String)] = []

        for ext in enabledExtensions {
            guard let commands = ext.manifest.commands else { continue }
            for (name, cmd) in commands {
                let shortcutStr = cmd.suggestedKey?.mac ?? cmd.suggestedKey?.default ?? ""
                guard !shortcutStr.isEmpty else { continue }
                if let parsed = parseShortcut(shortcutStr) {
                    shortcuts.append((ext.id, name, parsed.modifiers, parsed.key))
                }
            }
        }

        guard !shortcuts.isEmpty else { return }

        commandMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            for shortcut in shortcuts {
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == shortcut.modifiers,
                   event.charactersIgnoringModifiers?.lowercased() == shortcut.keyCode.lowercased() {
                    self?.dispatchCommand(shortcut.commandName, extensionID: shortcut.extensionID)
                    return nil // consume the event
                }
            }
            return event
        }
    }

    private func parseShortcut(_ shortcut: String) -> (modifiers: NSEvent.ModifierFlags, key: String)? {
        let parts = shortcut.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }

        var modifiers: NSEvent.ModifierFlags = []
        let key = parts.last ?? ""

        for part in parts.dropLast() {
            switch part.lowercased() {
            case "ctrl", "control", "macctrl": modifiers.insert(.control)
            case "alt", "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "command", "cmd": modifiers.insert(.command)
            default: break
            }
        }

        return (modifiers, key)
    }

    private func dispatchCommand(_ commandName: String, extensionID: String) {
        let escapedName = commandName.replacingOccurrences(of: "'", with: "\\'")
        let js = "if (window.__extensionDispatchCommand) { window.__extensionDispatchCommand('\(escapedName)'); }"
        backgroundHost(for: extensionID)?.evaluateJavaScript(js)
    }

    // MARK: - Background Host Management

    func startBackground(for ext: WebExtension, isFirstRun: Bool = true, completion: (() -> Void)? = nil) {
        guard ext.manifest.background?.serviceWorker != nil else {
            completion?()
            return
        }
        let host = BackgroundHost(extension: ext)
        backgroundHosts[ext.id] = host
        host.start(isFirstRun: isFirstRun, completion: completion)
    }

    private func stopBackground(for extensionID: String) {
        backgroundHosts[extensionID]?.stop()
        backgroundHosts.removeValue(forKey: extensionID)
    }
}
