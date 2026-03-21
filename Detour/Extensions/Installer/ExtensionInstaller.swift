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

    /// Install an unpacked extension from a source directory.
    /// Copies files to Application Support and creates a database record.
    /// - Parameters:
    ///   - sourceURL: The directory containing the unpacked extension files.
    ///   - publicKey: Optional DER-encoded public key from a CRX3 header.
    static func install(from sourceURL: URL, publicKey: Data? = nil) throws -> WebExtension {
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

        // Derive extension ID: CRX public key > manifest "key" field > fallback UUID
        let extensionID: String
        if let publicKey {
            extensionID = deriveExtensionID(from: publicKey)
        } else if let manifestKey = manifest.key,
                  let keyData = Data(base64Encoded: manifestKey) {
            extensionID = deriveExtensionID(from: keyData)
        } else {
            extensionID = UUID().uuidString
        }

        // Copy extension files to Application Support
        let destDir = detourDataDirectory().appendingPathComponent("Extensions/\(extensionID)")

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

        log.info("Install complete: \(manifest.name, privacy: .public) (\(extensionID, privacy: .public))")
        return WebExtension(id: extensionID, manifest: manifest, basePath: destDir, isEnabled: true)
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
