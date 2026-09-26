import Foundation
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-updater")

/// Replacing an installed extension's files with a newer or edited copy
/// (TASK-113). Both paths go through `install(from:publicKey:options:)`, which
/// already unloads the old contexts, keeps per-profile enablement and saved
/// permission decisions, rehomes open extension pages and owes
/// `runtime.onInstalled` its `update`; what is added here is the gate in front.
extension ExtensionManager {

    enum UpdateApplication: Equatable {
        case installed(version: String)
        /// Installed but left disabled until the user accepts the added permissions.
        case installedPendingPermissions(version: String, delta: ExtensionUpdatePolicy.PermissionDelta)
    }

    enum UpdateError: LocalizedError {
        case notInstalled(String)
        case notUnpacked(String)
        case sourceFolderMissing(URL?)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let id): return "extension \(id) is not installed"
            case .notUnpacked(let id): return "extension \(id) was not loaded from a folder"
            case .sourceFolderMissing(let url):
                if let url { return "the folder \(url.path) no longer holds a manifest.json" }
                return "the folder this extension was loaded from is not recorded"
            }
        }
    }

    /// Install the unpacked contents of a verified update CRX over the installed
    /// extension. `publicKey` is the CRX's verified signing key; the id it derives
    /// must be `extensionID`, and the manifest's version must be newer.
    @MainActor
    @discardableResult
    func applyUpdate(from unpackedDir: URL, publicKey: Data?, to extensionID: String) throws -> UpdateApplication {
        guard let installed = self.extension(withID: extensionID) else {
            throw UpdateError.notInstalled(extensionID)
        }
        let manifest = try ExtensionManifest.parse(at: unpackedDir.appendingPathComponent("manifest.json"))
        let candidateID = publicKey.map(ExtensionInstaller.deriveExtensionID) ?? extensionID
        try ExtensionUpdatePolicy.validateCandidate(installedID: extensionID, installedVersion: installed.manifest.version,
                                                    candidateID: candidateID, candidateVersion: manifest.version)
        log.notice("Updating \(extensionID, privacy: .public) from \(installed.manifest.version, privacy: .public) to \(manifest.version, privacy: .public)")
        return try replace(installed, from: unpackedDir, publicKey: publicKey, manifest: manifest,
                           forcedID: nil, source: installed.source,
                           updateURL: ExtensionSource.pollableUpdateURL(manifest.updateURL) ?? installed.updateURL,
                           sourcePath: installed.sourcePath)
    }

    /// Reinstall an unpacked extension from the folder it was loaded from, keeping
    /// its id (Chrome's developer-mode Reload). Any version is accepted; permissions
    /// the edited manifest adds are held for approval like an update's.
    @MainActor
    @discardableResult
    func reloadUnpacked(id extensionID: String) throws -> UpdateApplication {
        guard let installed = self.extension(withID: extensionID) else {
            throw UpdateError.notInstalled(extensionID)
        }
        guard installed.source == .unpacked else { throw UpdateError.notUnpacked(extensionID) }
        guard let sourcePath = installed.sourcePath,
              FileManager.default.fileExists(atPath: sourcePath.appendingPathComponent("manifest.json").path) else {
            throw UpdateError.sourceFolderMissing(installed.sourcePath)
        }
        let manifest = try ExtensionManifest.parse(at: sourcePath.appendingPathComponent("manifest.json"))
        log.notice("Reloading unpacked \(extensionID, privacy: .public) from \(sourcePath.path, privacy: .public)")
        return try replace(installed, from: sourcePath, publicKey: nil, manifest: manifest,
                           forcedID: extensionID, source: .unpacked, updateURL: nil, sourcePath: sourcePath)
    }

    @MainActor
    private func replace(_ installed: WebExtension, from sourceDir: URL, publicKey: Data?,
                         manifest: ExtensionManifest, forcedID: String?, source: ExtensionSource,
                         updateURL: URL?, sourcePath: URL?) throws -> UpdateApplication {
        // Permissions the user has not accepted yet: what this manifest adds over
        // the installed one, plus anything an earlier update is still waiting on
        // — an approval the user never gave does not lapse because another
        // version arrived.
        let added = ExtensionUpdatePolicy.addedPermissions(from: installed.manifest, to: manifest)
        let pendingDelta = (installed.pendingPermissionApproval?.delta ?? .none).merged(with: added)

        var options = ExtensionInstaller.Options()
        options.source = source
        options.updateURL = updateURL
        options.sourcePath = sourcePath
        options.forcedID = forcedID
        if pendingDelta.isEmpty {
            options.enabled = installed.isEnabled
        } else {
            options.enabled = false
            options.pendingPermissionApproval = .init(version: manifest.version, delta: pendingDelta)
            log.notice("\(installed.id, privacy: .public) \(manifest.version, privacy: .public) adds permissions; installed disabled pending approval: \(pendingDelta.permissions.joined(separator: ","), privacy: .public) / \(pendingDelta.hostPermissions.joined(separator: ","), privacy: .public)")
        }

        let ext = try install(from: sourceDir, publicKey: publicKey, options: options)
        if let pending = ext.pendingPermissionApproval {
            return .installedPendingPermissions(version: ext.manifest.version, delta: pending.delta)
        }
        return .installed(version: ext.manifest.version)
    }

    /// The user accepted the permissions an update added: clear the wait and turn
    /// the extension back on (globally; per-profile choices were never touched).
    @MainActor
    func approvePendingPermissions(id extensionID: String) {
        guard let ext = self.extension(withID: extensionID) else { return }
        ext.pendingPermissionApproval = nil
        AppDatabase.shared.setExtensionPendingPermissionApproval(id: extensionID, json: nil)
        log.notice("Pending permissions approved for \(extensionID, privacy: .public); enabling")
        setEnabled(id: extensionID, enabled: true)
    }
}
