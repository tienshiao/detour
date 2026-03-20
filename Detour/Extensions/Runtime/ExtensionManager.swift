import Foundation
import WebKit

/// Singleton lifecycle manager for web extensions.
/// Owns the list of loaded extensions, their background hosts, and the content script injector.
class ExtensionManager {
    static let shared = ExtensionManager()

    var extensions: [WebExtension] = []
    var backgroundHosts: [String: BackgroundHost] = [:]
    var offscreenHosts: [String: OffscreenDocumentHost] = [:]
    var contextMenuItems: [String: [ContextMenuItem]] = [:]

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

    init() {}

    /// Initialize: load installed extensions from the database and start enabled ones.
    func initialize() {
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
                print("[ExtensionManager] Failed to decode manifest for extension \(record.id)")
                continue
            }
            let ext = WebExtension(id: record.id, manifest: manifest, basePath: basePath, isEnabled: record.isEnabled)
            extensions.append(ext)

            if ext.isEnabled {
                startBackground(for: ext)
            }
        }

        // Register tab observer for chrome.tabs events
        TabStore.shared.addObserver(tabObserver)

        // Observe tab activation events from BrowserWindowController
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTabActivated(_:)),
            name: Self.tabActivatedNotification, object: nil
        )
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
    func install(from sourceURL: URL) throws -> WebExtension {
        let ext = try ExtensionInstaller.install(from: sourceURL)
        extensions.append(ext)
        startBackground(for: ext)
        injectIntoExistingTabs(extension: ext)
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
            print("[ExtensionManager] dispatchContextMenuClicked: JSON serialization failed")
            return
        }

        let js = "if (window.__extensionDispatchContextMenuClicked) { window.__extensionDispatchContextMenuClicked(\(infoJSON), \(tabJSON)); }"
        backgroundHost(for: extensionID)?.evaluateJavaScript(js)
    }

    /// Uninstall an extension.
    func uninstall(id: String) {
        stopBackground(for: id)
        offscreenHosts[id]?.stop()
        offscreenHosts.removeValue(forKey: id)
        contextMenuItems.removeValue(forKey: id)
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
        ext.isEnabled = enabled
        AppDatabase.shared.setEnabled(id: id, enabled: enabled)

        if enabled {
            startBackground(for: ext)
        } else {
            stopBackground(for: id)
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

    // MARK: - Background Host Management

    private func startBackground(for ext: WebExtension) {
        guard ext.manifest.background?.serviceWorker != nil else { return }
        let host = BackgroundHost(extension: ext)
        backgroundHosts[ext.id] = host
        host.start()
    }

    private func stopBackground(for extensionID: String) {
        backgroundHosts[extensionID]?.stop()
        backgroundHosts.removeValue(forKey: extensionID)
    }
}
