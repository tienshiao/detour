import Foundation

/// Handles loading unpacked extension directories: copies files, parses manifest, creates DB records.
struct ExtensionInstaller {

    enum InstallerError: LocalizedError {
        case manifestNotFound
        case invalidManifest(String)
        case notMV3
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .manifestNotFound: return "manifest.json not found in extension directory"
            case .invalidManifest(let msg): return "Invalid manifest: \(msg)"
            case .notMV3: return "Only Manifest V3 extensions are supported"
            case .copyFailed(let msg): return "Failed to copy extension files: \(msg)"
            }
        }
    }

    /// Install an unpacked extension from a source directory.
    /// Copies files to Application Support and creates a database record.
    static func install(from sourceURL: URL) throws -> WebExtension {
        let manifestURL = sourceURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw InstallerError.manifestNotFound
        }

        let manifest: ExtensionManifest
        do {
            manifest = try ExtensionManifest.parse(at: manifestURL)
        } catch {
            throw InstallerError.invalidManifest(error.localizedDescription)
        }

        guard manifest.manifestVersion == 3 else {
            throw InstallerError.notMV3
        }

        // Generate a unique ID for this extension
        let extensionID = UUID().uuidString

        // Copy extension files to Application Support
        let destDir = detourDataDirectory().appendingPathComponent("Extensions/\(extensionID)")

        do {
            try FileManager.default.createDirectory(at: destDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destDir)
        } catch {
            throw InstallerError.copyFailed(error.localizedDescription)
        }

        // Resolve i18n placeholders in name and description
        let i18nMessages = ExtensionI18n.loadDefaultMessages(basePath: destDir, defaultLocale: manifest.defaultLocale)
        let resolvedName = ExtensionI18n.resolve(manifest.name, messages: i18nMessages)

        // Save to database
        let manifestData = try manifest.toJSONData()
        let record = ExtensionRecord(
            id: extensionID,
            name: resolvedName,
            version: manifest.version,
            manifestJSON: manifestData,
            basePath: destDir.path,
            isEnabled: true,
            installedAt: Date().timeIntervalSince1970
        )
        AppDatabase.shared.saveExtension(record)

        return WebExtension(id: extensionID, manifest: manifest, basePath: destDir, isEnabled: true)
    }
}
