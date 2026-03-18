import Foundation
import WebKit

/// Singleton lifecycle manager for web extensions.
/// Owns the list of loaded extensions, their background hosts, and the content script injector.
class ExtensionManager {
    static let shared = ExtensionManager()

    var extensions: [WebExtension] = []
    var backgroundHosts: [String: BackgroundHost] = [:]

    let injector = ContentScriptInjector()

    /// Notification posted when the set of enabled extensions changes.
    static let extensionsDidChangeNotification = Notification.Name("ExtensionManagerExtensionsDidChange")

    init() {}

    /// Initialize: load installed extensions from the database and start enabled ones.
    func initialize() {
        let records = ExtensionDatabase.shared.loadExtensions()
        for record in records {
            guard let manifest = try? JSONDecoder().decode(ExtensionManifest.self, from: record.manifestJSON) else {
                print("[ExtensionManager] Failed to decode manifest for extension \(record.id)")
                continue
            }
            let basePath = URL(fileURLWithPath: record.basePath)
            let ext = WebExtension(id: record.id, manifest: manifest, basePath: basePath, isEnabled: record.isEnabled)
            extensions.append(ext)

            if ext.isEnabled {
                startBackground(for: ext)
            }
        }
    }

    /// All currently enabled extensions.
    var enabledExtensions: [WebExtension] {
        extensions.filter { $0.isEnabled }
    }

    /// Look up an extension by ID.
    func `extension`(withID id: String) -> WebExtension? {
        extensions.first { $0.id == id }
    }

    /// Get the background host for an extension.
    func backgroundHost(for extensionID: String) -> BackgroundHost? {
        backgroundHosts[extensionID]
    }

    /// Install an extension from an unpacked directory.
    @discardableResult
    func install(from sourceURL: URL) throws -> WebExtension {
        let ext = try ExtensionInstaller.install(from: sourceURL)
        extensions.append(ext)
        startBackground(for: ext)
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
        return ext
    }

    /// Uninstall an extension.
    func uninstall(id: String) {
        stopBackground(for: id)
        extensions.removeAll { $0.id == id }
        ExtensionDatabase.shared.deleteExtension(id: id)

        // Remove extension files
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let extDir = appSupport.appendingPathComponent("Detour/Extensions/\(id)")
        try? FileManager.default.removeItem(at: extDir)

        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
    }

    /// Enable or disable an extension.
    func setEnabled(id: String, enabled: Bool) {
        guard let ext = self.extension(withID: id) else { return }
        ext.isEnabled = enabled
        ExtensionDatabase.shared.setEnabled(id: id, enabled: enabled)

        if enabled {
            startBackground(for: ext)
        } else {
            stopBackground(for: id)
        }

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
