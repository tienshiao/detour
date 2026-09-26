import Foundation
import CryptoKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-installer")

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

    /// What an install records beyond the files (TASK-113). The defaults describe
    /// an unpacked load whose folder is not remembered, which is what every
    /// install was before the source was tracked.
    struct Options {
        var source: ExtensionSource = .unpacked
        /// The update2 endpoint to poll; nil means the install never updates.
        var updateURL: URL? = nil
        /// The folder an unpacked extension can be reloaded from.
        var sourcePath: URL? = nil
        /// Keep this id instead of deriving one — a reload of an unpacked
        /// extension whose manifest has no key must not mint a new UUID.
        var forcedID: String? = nil
        /// The global enabled flag to record. An update that adds permissions
        /// installs disabled, with `pendingPermissionApproval` saying why.
        var enabled: Bool = true
        var pendingPermissionApproval: ExtensionUpdatePolicy.PendingApproval? = nil

        init() {}
    }

    /// Install an unpacked extension from a source directory.
    /// Copies files to Application Support and creates a database record.
    /// - Parameters:
    ///   - sourceURL: The directory containing the unpacked extension files.
    ///   - publicKey: Optional DER-encoded public key from a CRX3 header.
    ///   - options: source bookkeeping; see `Options`.
    static func install(from sourceURL: URL, publicKey: Data? = nil,
                        options: Options = Options()) throws -> WebExtension {
        log.info("Installing extension from \(sourceURL.path)")
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

        // Derive extension ID: forced (reload) > CRX public key > manifest "key" field > fallback UUID
        let extensionID: String
        if let forcedID = options.forcedID {
            extensionID = forcedID
        } else if let publicKey {
            extensionID = deriveExtensionID(from: publicKey)
        } else if let manifestKey = manifest.key,
                  let keyData = Data(base64Encoded: manifestKey) {
            extensionID = deriveExtensionID(from: keyData)
        } else {
            extensionID = UUID().uuidString
        }

        // Copy extension files to Application Support
        let destDir = detourDataDirectory().appendingPathComponent("Extensions/\(extensionID)")
        // A reload from the install folder itself would delete the files it is
        // about to copy.
        guard sourceURL.standardizedFileURL.resolvingSymlinksInPath() != destDir.standardizedFileURL.resolvingSymlinksInPath() else {
            throw InstallerError.copyFailed("the source folder is the installed copy")
        }

        do {
            try FileManager.default.createDirectory(at: destDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            // If a previous installation with the same ID exists, replace it
            if FileManager.default.fileExists(atPath: destDir.path) {
                try FileManager.default.removeItem(at: destDir)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destDir)
        } catch {
            log.error("Failed to copy extension files: \(error.localizedDescription)")
            throw InstallerError.copyFailed(error.localizedDescription)
        }

        let resolvedName = WebExtension.resolveI18nName(manifest.name, basePath: destDir, defaultLocale: manifest.defaultLocale)

        // Save to database
        let manifestData = try manifest.toJSONData()
        let pendingJSON = try options.pendingPermissionApproval.map { try JSONEncoder().encode($0) }
        let record = ExtensionRecord(
            id: extensionID,
            name: resolvedName,
            version: manifest.version,
            manifestJSON: manifestData,
            basePath: destDir.path,
            isEnabled: options.enabled,
            installedAt: Date().timeIntervalSince1970,
            source: options.source,
            updateURL: options.updateURL?.absoluteString,
            sourcePath: options.sourcePath?.path,
            pendingPermissionApprovalJSON: pendingJSON
        )
        AppDatabase.shared.saveExtension(record)

        log.info("Install complete: \(manifest.name, privacy: .public) (\(extensionID, privacy: .public)) from \(options.source.rawValue, privacy: .public)")
        let ext = WebExtension(id: extensionID, manifest: manifest, basePath: destDir, isEnabled: options.enabled)
        ext.source = options.source
        ext.updateURL = options.updateURL
        ext.sourcePath = options.sourcePath
        ext.pendingPermissionApproval = options.pendingPermissionApproval
        return ext
    }

    /// Derive a Chrome-compatible 32-character extension ID from a DER-encoded public key.
    ///
    /// Chrome's algorithm:
    /// 1. SHA-256 hash of the public key
    /// 2. Take first 16 bytes
    /// 3. Encode each byte as two chars: chr('a' + (byte >> 4)) + chr('a' + (byte & 0xf))
    ///
    /// This produces a 32-character string using only letters a–p.
    static func deriveExtensionID(from publicKey: Data) -> String {
        let hash = SHA256.hash(data: publicKey)
        let first16 = Array(hash.prefix(16))

        var result = ""
        result.reserveCapacity(32)
        for byte in first16 {
            let hi = Int(byte >> 4)
            let lo = Int(byte & 0x0F)
            result.append(Character(UnicodeScalar(Int(UnicodeScalar("a").value) + hi)!))
            result.append(Character(UnicodeScalar(Int(UnicodeScalar("a").value) + lo)!))
        }
        return result
    }
}
